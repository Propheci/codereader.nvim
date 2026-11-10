//! `codereader`: CLI over the Note store and Trails.
//!
//! With `--json`, every command prints one envelope on stdout:
//! `{"schema_version": N, "ok": true, "data": ...}` or
//! `{"schema_version": N, "ok": false, "error": "..."}` (exit code 1).
//! Without it, output is short human-readable text.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand, ValueEnum};
use serde::{Deserialize, Serialize};

use codereader::SCHEMA_VERSION;
use codereader::ids;
use codereader::note::{Anchor, Note, normalize_body};
use codereader::project::{Project, ProjectOptions};
use codereader::resolve::{self, Resolution, Status, SymbolRange};
use codereader::store::NoteStore;
use codereader::trail::{self, Location, Stop, StopStatus, Trail, TrailStore};

#[derive(Parser)]
#[command(name = "codereader", version, about = "Notes and Trails for reading large codebases")]
struct Cli {
    /// Print a JSON envelope (for the Neovim plugin and scripts).
    #[arg(long, global = true)]
    json: bool,
    /// Project root (default: nearest git root above the cwd, else the cwd).
    #[arg(long, global = true)]
    root: Option<PathBuf>,
    /// Fixed Project name (default: derived from the root path).
    #[arg(long, global = true)]
    project: Option<String>,
    /// Base directory for Notes and Trails stored outside the repo.
    #[arg(long, global = true, env = "CODEREADER_DATA_DIR")]
    data_dir: Option<PathBuf>,
    /// Store Notes and Trails in `<root>/.codereader/` instead.
    #[arg(long, global = true)]
    in_repo: bool,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Show the Project and where its data is stored.
    Project,
    /// Add, list, edit and re-attach Notes.
    #[command(subcommand)]
    Note(NoteCmd),
    /// Re-find every Note anchored in one file. Reads optional JSON on stdin:
    /// `{"text": "<buffer text>", "symbols": [{"symbol": [..], "start_line": N, "end_line": M}]}`.
    Resolve {
        #[arg(long)]
        path: PathBuf,
        #[arg(long)]
        stdin: bool,
    },
    /// Full-text search over Note bodies (case-insensitive).
    Search {
        query: String,
        #[arg(long)]
        tag: Option<String>,
    },
    /// Record and walk Trails.
    #[command(subcommand)]
    Trail(TrailCmd),
}

#[derive(Subcommand)]
enum NoteCmd {
    /// Add a Note. The Anchor kind is inferred if `--kind` is not given:
    /// `--symbol` -> symbol, `--start` -> range, `--path` -> file, else project.
    Add {
        #[command(flatten)]
        anchor: AnchorArgs,
        #[arg(short, long)]
        message: String,
    },
    /// List Notes.
    List {
        /// Only Notes anchored in this file.
        #[arg(long)]
        path: Option<PathBuf>,
        #[arg(long)]
        tag: Option<String>,
        /// Only Notes with this status (implies --resolve).
        #[arg(long, value_enum)]
        status: Option<StatusArg>,
        /// Re-find each Anchor from the files on disk.
        #[arg(long)]
        resolve: bool,
    },
    Show {
        id: String,
    },
    Edit {
        id: String,
        #[arg(short, long)]
        message: String,
    },
    Delete {
        id: String,
    },
    /// Accept the code under a Drifted Note as what the Note is about.
    Confirm {
        id: String,
        /// Read the current file text from stdin (unsaved buffer).
        #[arg(long)]
        text_stdin: bool,
    },
    /// Move a Note (or an Orphan) to a new Anchor.
    Attach {
        id: String,
        #[command(flatten)]
        anchor: AnchorArgs,
    },
}

#[derive(Args)]
struct AnchorArgs {
    #[arg(long, value_enum)]
    kind: Option<KindArg>,
    #[arg(long)]
    path: Option<PathBuf>,
    /// First line (1-based).
    #[arg(long)]
    start: Option<usize>,
    /// Last line (1-based, inclusive; default: --start).
    #[arg(long)]
    end: Option<usize>,
    /// One container name per flag, outside in: `--symbol Svc --symbol login`.
    #[arg(long = "symbol")]
    symbol: Vec<String>,
    /// Read the current file text from stdin (unsaved buffer).
    #[arg(long)]
    text_stdin: bool,
}

#[derive(Clone, Copy, ValueEnum)]
enum KindArg {
    Range,
    Symbol,
    File,
    Project,
}

#[derive(Clone, Copy, ValueEnum)]
enum StatusArg {
    Ok,
    Moved,
    Drifted,
    Orphan,
}

impl StatusArg {
    fn matches(self, s: Status) -> bool {
        matches!(
            (self, s),
            (StatusArg::Ok, Status::Ok)
                | (StatusArg::Moved, Status::Moved)
                | (StatusArg::Drifted, Status::Drifted)
                | (StatusArg::Orphan, Status::Orphan)
        )
    }
}

#[derive(Subcommand)]
enum TrailCmd {
    /// Start a Trail (unnamed if NAME is omitted).
    New { name: Option<String> },
    List,
    /// Show a Trail's Stops; `--resolve` re-finds each Stop on disk.
    Show {
        id: String,
        #[arg(long)]
        resolve: bool,
    },
    /// Record a Stop. With `--from-*`, records a jump: the origin is added
    /// first unless it is the current Stop.
    Push {
        id: String,
        #[command(flatten)]
        to: StopArgs,
        #[arg(long, default_value = "manual")]
        via: String,
        #[arg(long)]
        from_path: Option<PathBuf>,
        #[arg(long)]
        from_line: Option<usize>,
        #[arg(long, default_value_t = 1)]
        from_col: usize,
        #[arg(long)]
        from_snapshot: Option<String>,
        #[arg(long = "from-symbol")]
        from_symbol: Vec<String>,
    },
    /// Move to the parent Stop.
    Back { id: String },
    /// Move to the most recently visited child Stop.
    Forward { id: String },
    Goto { id: String, stop: String },
    Rename { id: String, name: String },
    Delete { id: String },
}

#[derive(Args)]
struct StopArgs {
    #[arg(long)]
    path: PathBuf,
    #[arg(long)]
    line: usize,
    #[arg(long, default_value_t = 1)]
    col: usize,
    /// The line's text (default: read from the file on disk).
    #[arg(long)]
    snapshot: Option<String>,
    #[arg(long = "symbol")]
    symbol: Vec<String>,
}

#[derive(Serialize)]
struct Envelope<'a, T: Serialize> {
    schema_version: u32,
    ok: bool,
    data: &'a T,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let json = cli.json;
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            if json {
                println!(
                    "{}",
                    serde_json::json!({ "schema_version": SCHEMA_VERSION, "ok": false, "error": format!("{e:#}") })
                );
            } else {
                eprintln!("codereader: {e:#}");
            }
            ExitCode::FAILURE
        }
    }
}

struct Ctx {
    json: bool,
    cwd: PathBuf,
    project: Project,
    notes: NoteStore,
    trails: TrailStore,
}

impl Ctx {
    fn emit<T: Serialize>(&self, data: &T, human: impl FnOnce() -> String) -> Result<()> {
        if self.json {
            let env = Envelope { schema_version: SCHEMA_VERSION, ok: true, data };
            println!("{}", serde_json::to_string(&env)?);
        } else {
            let s = human();
            if !s.is_empty() {
                println!("{s}");
            }
        }
        Ok(())
    }

    fn abs(&self, p: &Path) -> PathBuf {
        self.project.absolutize(&self.cwd, p)
    }

    fn stored(&self, p: &Path) -> String {
        self.project.to_stored(&self.abs(p))
    }
}

fn warn(warnings: Vec<String>) {
    for w in warnings {
        eprintln!("codereader: warning: {w}");
    }
}

fn read_stdin() -> Result<String> {
    let mut s = String::new();
    std::io::stdin().read_to_string(&mut s).context("read stdin")?;
    Ok(s)
}

fn run(cli: Cli) -> Result<()> {
    let cwd = std::env::current_dir().context("current directory")?;
    let project = Project::discover(ProjectOptions {
        cwd: cwd.clone(),
        root: cli.root,
        name: cli.project,
        data_dir: cli.data_dir,
        in_repo: cli.in_repo,
    })?;
    let ctx = Ctx {
        json: cli.json,
        notes: NoteStore::new(&project.store_dir),
        trails: TrailStore::new(&project.store_dir),
        cwd,
        project,
    };
    match cli.cmd {
        Cmd::Project => ctx.emit(&ctx.project, || {
            format!(
                "{}\n  root:  {}\n  store: {}",
                ctx.project.name,
                ctx.project.root.display(),
                ctx.project.store_dir.display()
            )
        }),
        Cmd::Note(c) => note_cmd(&ctx, c),
        Cmd::Resolve { path, stdin } => resolve_cmd(&ctx, &path, stdin),
        Cmd::Search { query, tag } => {
            let (all, w) = ctx.notes.list()?;
            warn(w);
            let q = query.to_lowercase();
            let hits: Vec<NoteView> = all
                .iter()
                .filter(|n| {
                    n.body.to_lowercase().contains(&q)
                        || n.anchor.path().is_some_and(|p| p.to_lowercase().contains(&q))
                })
                .filter(|n| tag.as_deref().is_none_or(|t| n.has_tag(t)))
                .map(|n| NoteView::new(&ctx.project, n, None))
                .collect();
            ctx.emit(&hits, || human_notes(&hits))
        }
        Cmd::Trail(c) => trail_cmd(&ctx, c),
    }
}

// Notes ---------------------------------------------------------------------

#[derive(Serialize)]
struct NoteView<'a> {
    #[serde(flatten)]
    note: &'a Note,
    body: &'a str,
    title: String,
    tags: Vec<String>,
    /// Absolute path of the anchored file, for the editor to open.
    #[serde(skip_serializing_if = "Option::is_none")]
    abs_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    resolution: Option<Resolution>,
}

impl<'a> NoteView<'a> {
    fn new(project: &Project, note: &'a Note, resolution: Option<Resolution>) -> Self {
        NoteView {
            note,
            body: &note.body,
            title: note.title(),
            tags: note.tags(),
            abs_path: note.anchor.path().map(|p| project.to_abs(p).to_string_lossy().into_owned()),
            resolution,
        }
    }
}

fn status_word(s: Status) -> &'static str {
    match s {
        Status::Ok => "",
        Status::Moved => " [moved]",
        Status::Drifted => " [drifted]",
        Status::Orphan => " [orphan]",
    }
}

fn human_notes(views: &[NoteView]) -> String {
    if views.is_empty() {
        return "no notes".into();
    }
    views
        .iter()
        .map(|v| {
            let mut anchor = v.note.anchor.clone();
            if let Some(Resolution { start_line: Some(s), end_line: Some(e), .. }) = v.resolution {
                anchor.set_lines(s, e);
            }
            format!(
                "{}  {}  {}{}",
                v.note.id,
                anchor.describe(),
                v.title,
                v.resolution.map_or("", |r| status_word(r.status))
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Reads each anchored file once per command.
#[derive(Default)]
struct FileCache(HashMap<PathBuf, Option<String>>);

impl FileCache {
    fn get(&mut self, path: PathBuf) -> Option<&str> {
        self.0.entry(path).or_insert_with_key(|p| fs::read_to_string(p).ok()).as_deref()
    }
}

/// Re-find `note`'s Anchor and save it if it moved.
fn resolve_and_save(
    ctx: &Ctx,
    cache: &mut FileCache,
    note: &mut Note,
    text: Option<&str>,
    symbols: &[SymbolRange],
) -> Result<Resolution> {
    let disk = match (text, note.anchor.path()) {
        (None, Some(p)) => cache.get(ctx.project.to_abs(p)),
        _ => None,
    };
    let res = resolve::resolve_note(note, text.or(disk), symbols);
    if resolve::apply(note, &res) {
        ctx.notes.save(note)?;
    }
    Ok(res)
}

fn build_anchor(ctx: &Ctx, args: &AnchorArgs, stdin_text: Option<&str>) -> Result<Anchor> {
    let kind = args.kind.unwrap_or(if !args.symbol.is_empty() {
        KindArg::Symbol
    } else if args.start.is_some() {
        KindArg::Range
    } else if args.path.is_some() {
        KindArg::File
    } else {
        KindArg::Project
    });
    if matches!(kind, KindArg::Project) {
        return Ok(Anchor::Project);
    }
    let path = args.path.as_ref().context("--path is required for this anchor kind")?;
    let abs = ctx.abs(path);
    let stored = ctx.project.to_stored(&abs);
    if matches!(kind, KindArg::File) {
        if stdin_text.is_none() && !abs.is_file() {
            bail!("no such file: {}", abs.display());
        }
        return Ok(Anchor::File { path: stored });
    }
    let start = args.start.context("--start is required for range and symbol anchors")?;
    let end = args.end.unwrap_or(start);
    let text = match stdin_text {
        Some(t) => t.to_string(),
        None => fs::read_to_string(&abs).with_context(|| format!("read {}", abs.display()))?,
    };
    let snapshot = resolve::snapshot(&text, start, end)?;
    Ok(match kind {
        KindArg::Symbol => {
            if args.symbol.is_empty() {
                bail!("--symbol is required for a symbol anchor");
            }
            Anchor::Symbol { path: stored, symbol: args.symbol.clone(), start_line: start, end_line: end, snapshot }
        }
        _ => Anchor::Range { path: stored, start_line: start, end_line: end, snapshot },
    })
}

fn note_cmd(ctx: &Ctx, cmd: NoteCmd) -> Result<()> {
    match cmd {
        NoteCmd::Add { anchor, message } => {
            let text = if anchor.text_stdin { Some(read_stdin()?) } else { None };
            let a = build_anchor(ctx, &anchor, text.as_deref())?;
            let note = ctx.notes.create(a, &message)?;
            let view = NoteView::new(&ctx.project, &note, None);
            ctx.emit(&view, || format!("added {}  {}", note.id, note.anchor.describe()))
        }
        NoteCmd::List { path, tag, status, resolve } => {
            let (all, w) = ctx.notes.list()?;
            warn(w);
            let want_path = path.map(|p| ctx.stored(&p));
            let mut picked: Vec<Note> = all
                .into_iter()
                .filter(|n| want_path.as_deref().is_none_or(|p| n.anchor.path() == Some(p)))
                .filter(|n| tag.as_deref().is_none_or(|t| n.has_tag(t)))
                .collect();
            let mut resolutions = Vec::with_capacity(picked.len());
            if resolve || status.is_some() {
                let mut cache = FileCache::default();
                for n in &mut picked {
                    resolutions.push(Some(resolve_and_save(ctx, &mut cache, n, None, &[])?));
                }
            } else {
                resolutions.resize(picked.len(), None);
            }
            let views: Vec<NoteView> = picked
                .iter()
                .zip(resolutions)
                .filter(|(_, r)| match (status, r) {
                    (Some(s), Some(r)) => s.matches(r.status),
                    _ => true,
                })
                .map(|(n, r)| NoteView::new(&ctx.project, n, r))
                .collect();
            ctx.emit(&views, || human_notes(&views))
        }
        NoteCmd::Show { id } => {
            let mut note = ctx.notes.get(&id)?;
            let res = resolve_and_save(ctx, &mut FileCache::default(), &mut note, None, &[])?;
            let view = NoteView::new(&ctx.project, &note, Some(res));
            ctx.emit(&view, || format!("{}\n\n{}", human_notes(std::slice::from_ref(&view)), note.body))
        }
        NoteCmd::Edit { id, message } => {
            let mut note = ctx.notes.get(&id)?;
            note.body = normalize_body(&message);
            note.updated = ids::now();
            ctx.notes.save(&note)?;
            let view = NoteView::new(&ctx.project, &note, None);
            ctx.emit(&view, || format!("edited {id}"))
        }
        NoteCmd::Delete { id } => {
            ctx.notes.delete(&id)?;
            ctx.emit(&serde_json::json!({ "id": id }), || format!("deleted {id}"))
        }
        NoteCmd::Confirm { id, text_stdin } => {
            let mut note = ctx.notes.get(&id)?;
            let text = if text_stdin { Some(read_stdin()?) } else { None };
            let mut cache = FileCache::default();
            let res = resolve_and_save(ctx, &mut cache, &mut note, text.as_deref(), &[])?;
            if !res.is_found() {
                bail!("note {id} is an Orphan; attach it to code first");
            }
            if let (Some(s), Some(e), Some(p)) = (res.start_line, res.end_line, note.anchor.path()) {
                let current = match text.as_deref() {
                    Some(t) => t.to_string(),
                    None => cache.get(ctx.project.to_abs(p)).context("anchored file is unreadable")?.to_string(),
                };
                note.anchor.set_snapshot(resolve::snapshot(&current, s, e)?);
            }
            note.updated = ids::now();
            ctx.notes.save(&note)?;
            let view = NoteView::new(&ctx.project, &note, Some(Resolution { status: Status::Ok, ..res }));
            ctx.emit(&view, || format!("confirmed {id}"))
        }
        NoteCmd::Attach { id, anchor } => {
            let mut note = ctx.notes.get(&id)?;
            let text = if anchor.text_stdin { Some(read_stdin()?) } else { None };
            note.anchor = build_anchor(ctx, &anchor, text.as_deref())?;
            note.updated = ids::now();
            ctx.notes.save(&note)?;
            let view = NoteView::new(&ctx.project, &note, None);
            ctx.emit(&view, || format!("attached {id}  {}", note.anchor.describe()))
        }
    }
}

#[derive(Deserialize, Default)]
struct ResolveInput {
    text: Option<String>,
    #[serde(default)]
    symbols: Vec<SymbolRange>,
}

fn resolve_cmd(ctx: &Ctx, path: &Path, stdin: bool) -> Result<()> {
    let input: ResolveInput = if stdin {
        let raw = read_stdin()?;
        if raw.trim().is_empty() { ResolveInput::default() } else { serde_json::from_str(&raw).context("parse stdin JSON")? }
    } else {
        ResolveInput::default()
    };
    let stored = ctx.stored(path);
    let (all, w) = ctx.notes.list()?;
    warn(w);
    let mut cache = FileCache::default();
    let mut picked: Vec<Note> = all.into_iter().filter(|n| n.anchor.path() == Some(stored.as_str())).collect();
    let mut resolutions = Vec::with_capacity(picked.len());
    for n in &mut picked {
        resolutions.push(resolve_and_save(ctx, &mut cache, n, input.text.as_deref(), &input.symbols)?);
    }
    let views: Vec<NoteView> =
        picked.iter().zip(resolutions).map(|(n, r)| NoteView::new(&ctx.project, n, Some(r))).collect();
    ctx.emit(&views, || human_notes(&views))
}

// Trails --------------------------------------------------------------------

#[derive(Serialize)]
struct TrailSummary<'a> {
    id: &'a str,
    name: Option<&'a str>,
    created: &'a str,
    updated: &'a str,
    current: Option<&'a str>,
    stop_count: usize,
}

impl<'a> TrailSummary<'a> {
    fn new(t: &'a Trail) -> Self {
        TrailSummary {
            id: &t.id,
            name: t.name.as_deref(),
            created: &t.created,
            updated: &t.updated,
            current: t.current.as_deref(),
            stop_count: t.stops.len(),
        }
    }
}

#[derive(Serialize)]
struct StopView<'a> {
    #[serde(flatten)]
    stop: &'a Stop,
    abs_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<StopStatus>,
}

#[derive(Serialize)]
struct TrailView<'a> {
    #[serde(flatten)]
    summary: TrailSummary<'a>,
    stops: Vec<StopView<'a>>,
}

fn trail_name(t: &Trail) -> &str {
    t.name.as_deref().unwrap_or("(unnamed)")
}

fn stop_view<'a>(ctx: &Ctx, s: &'a Stop, status: Option<StopStatus>) -> StopView<'a> {
    StopView { stop: s, abs_path: ctx.project.to_abs(&s.path).to_string_lossy().into_owned(), status }
}

/// Re-find every Stop on disk and save the Trail if any moved.
fn resolve_trail(ctx: &Ctx, id: &str) -> Result<(Trail, HashMap<String, StopStatus>)> {
    ctx.trails.update(id, |t| {
        let mut cache = FileCache::default();
        let mut statuses = HashMap::new();
        for s in &mut t.stops {
            let (status, line) = trail::resolve_stop(s, cache.get(ctx.project.to_abs(&s.path)));
            s.line = line;
            statuses.insert(s.id.clone(), status);
        }
        Ok(statuses)
    })
}

fn human_trail(t: &Trail, statuses: &HashMap<String, StopStatus>) -> String {
    let mut out = format!("{}  {}", t.id, trail_name(t));
    fn walk(t: &Trail, statuses: &HashMap<String, StopStatus>, parent: Option<&str>, depth: usize, out: &mut String) {
        for s in t.stops.iter().filter(|s| s.parent.as_deref() == parent) {
            let cur = if t.current.as_deref() == Some(s.id.as_str()) { ">" } else { " " };
            let lost = if statuses.get(&s.id) == Some(&StopStatus::Lost) { " [lost]" } else { "" };
            let sym = if s.symbol.is_empty() { String::new() } else { format!(" ({})", s.symbol.join(" > ")) };
            out.push_str(&format!(
                "\n{cur} {}{}  {}:{}{sym}  {}{lost}",
                "  ".repeat(depth),
                s.id,
                s.path,
                s.line,
                s.snapshot.trim()
            ));
            walk(t, statuses, Some(&s.id), depth + 1, out);
        }
    }
    walk(t, statuses, None, 0, &mut out);
    out
}

fn location(ctx: &Ctx, path: &Path, line: usize, col: usize, snapshot: Option<String>, symbol: Vec<String>) -> Result<Location> {
    let abs = ctx.abs(path);
    let snapshot = match snapshot {
        Some(s) => s,
        None => fs::read_to_string(&abs)
            .ok()
            .and_then(|t| t.lines().nth(line.saturating_sub(1)).map(str::to_string))
            .unwrap_or_default(),
    };
    Ok(Location { path: ctx.project.to_stored(&abs), line, col, snapshot, symbol })
}

/// Emit the current Stop after a move, re-found on disk so the editor jumps
/// to where the code is now.
fn emit_current(ctx: &Ctx, t: &Trail) -> Result<()> {
    let s = t.current_stop().context("trail has no current stop")?;
    let abs = ctx.project.to_abs(&s.path);
    let (status, line) = trail::resolve_stop(s, fs::read_to_string(&abs).ok().as_deref());
    let mut s = s.clone();
    s.line = line;
    let view = stop_view(ctx, &s, Some(status));
    ctx.emit(&view, || format!("{}  {}:{}  {}", s.id, s.path, s.line, s.snapshot.trim()))
}

fn trail_cmd(ctx: &Ctx, cmd: TrailCmd) -> Result<()> {
    match cmd {
        TrailCmd::New { name } => {
            let t = ctx.trails.create(name)?;
            ctx.emit(&TrailSummary::new(&t), || format!("started {}  {}", t.id, trail_name(&t)))
        }
        TrailCmd::List => {
            let (all, w) = ctx.trails.list()?;
            warn(w);
            let views: Vec<TrailSummary> = all.iter().map(TrailSummary::new).collect();
            ctx.emit(&views, || {
                if all.is_empty() {
                    return "no trails".into();
                }
                all.iter()
                    .map(|t| format!("{}  {}  ({} stops)", t.id, trail_name(t), t.stops.len()))
                    .collect::<Vec<_>>()
                    .join("\n")
            })
        }
        TrailCmd::Show { id, resolve } => {
            let (t, statuses) = if resolve { resolve_trail(ctx, &id)? } else { (ctx.trails.get(&id)?, HashMap::new()) };
            let view = TrailView {
                summary: TrailSummary::new(&t),
                stops: t.stops.iter().map(|s| stop_view(ctx, s, statuses.get(&s.id).copied())).collect(),
            };
            ctx.emit(&view, || human_trail(&t, &statuses))
        }
        TrailCmd::Push { id, to, via, from_path, from_line, from_col, from_snapshot, from_symbol } => {
            let to = location(ctx, &to.path, to.line, to.col, to.snapshot, to.symbol)?;
            let from = match (from_path, from_line) {
                (Some(p), Some(l)) => Some(location(ctx, &p, l, from_col, from_snapshot, from_symbol)?),
                (None, None) => None,
                _ => bail!("--from-path and --from-line go together"),
            };
            let (t, _) = ctx.trails.update(&id, |t| Ok(t.push(from, to, &via)))?;
            emit_current(ctx, &t)
        }
        TrailCmd::Back { id } => emit_current(ctx, &ctx.trails.update(&id, |t| t.back())?.0),
        TrailCmd::Forward { id } => emit_current(ctx, &ctx.trails.update(&id, |t| t.forward())?.0),
        TrailCmd::Goto { id, stop } => emit_current(ctx, &ctx.trails.update(&id, |t| t.goto(&stop))?.0),
        TrailCmd::Rename { id, name } => {
            let (t, _) = ctx.trails.update(&id, |t| {
                t.name = Some(name);
                Ok(())
            })?;
            ctx.emit(&TrailSummary::new(&t), || format!("renamed {}  {}", t.id, trail_name(&t)))
        }
        TrailCmd::Delete { id } => {
            ctx.trails.delete(&id)?;
            ctx.emit(&serde_json::json!({ "id": id }), || format!("deleted {id}"))
        }
    }
}
