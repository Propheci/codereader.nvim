//! Finding an Anchor again after Drift.
//!
//! All comparisons ignore leading/trailing whitespace on each line, so a
//! re-indent moves an Anchor but does not make its Note Drifted. The order of
//! attempts is:
//!
//! 1. the snapshot is still at the stored lines -> `Ok`;
//! 2. the snapshot appears verbatim elsewhere (nearest wins) -> `Moved`;
//! 3. (Symbol Anchors) the Lua side found the symbol -> `Ok`/`Moved`/`Drifted`;
//! 4. enough of the snapshot's lines still sit together -> `Drifted`;
//! 5. a one- or two-line snapshot was edited in place -> `Drifted`;
//! 6. otherwise -> `Orphan`.

use std::collections::{BTreeMap, HashMap};

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

use crate::note::{Anchor, Note};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    /// Found at the stored lines, unchanged.
    Ok,
    /// Found unchanged at different lines.
    Moved,
    /// Found, but the anchored code changed since the Reader wrote or last
    /// confirmed the Note.
    Drifted,
    /// Not found.
    Orphan,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Resolution {
    pub status: Status,
    /// Where the Anchor is now (1-based, inclusive); `None` for Orphans and
    /// for Anchors without lines.
    pub start_line: Option<usize>,
    pub end_line: Option<usize>,
}

impl Resolution {
    fn found(status: Status, start0: usize, end0: usize) -> Self {
        Self { status, start_line: Some(start0 + 1), end_line: Some(end0 + 1) }
    }
    fn whole(status: Status) -> Self {
        Self { status, start_line: None, end_line: None }
    }
    pub fn is_found(&self) -> bool {
        self.status != Status::Orphan
    }
}

/// A symbol location reported by the Lua side (Treesitter or LSP).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct SymbolRange {
    pub symbol: Vec<String>,
    pub start_line: usize,
    pub end_line: usize,
}

/// The snapshot for lines `start..=end` (1-based) of `text`.
pub fn snapshot(text: &str, start: usize, end: usize) -> Result<String> {
    let lines: Vec<&str> = text.lines().collect();
    if start == 0 || end < start || end > lines.len().max(1) {
        bail!("lines {start}-{end} are outside the file ({} lines)", lines.len());
    }
    if lines.is_empty() {
        return Ok(String::new());
    }
    Ok(lines[start - 1..end].join("\n"))
}

/// Resolve any Note's Anchor. `text` is the current content of the anchored
/// file (`None` if it cannot be read); `symbols` are optional symbol ranges
/// for that file.
pub fn resolve_note(note: &Note, text: Option<&str>, symbols: &[SymbolRange]) -> Resolution {
    match &note.anchor {
        Anchor::Project => Resolution::whole(Status::Ok),
        Anchor::File { .. } => {
            Resolution::whole(if text.is_some() { Status::Ok } else { Status::Orphan })
        }
        Anchor::Range { start_line, snapshot, .. } => match text {
            Some(t) => resolve_range(&t.lines().collect::<Vec<_>>(), *start_line, snapshot),
            None => Resolution::whole(Status::Orphan),
        },
        Anchor::Symbol { symbol, start_line, snapshot, .. } => match text {
            Some(t) => {
                let range = symbols
                    .iter()
                    .find(|s| &s.symbol == symbol)
                    .map(|s| (s.start_line, s.end_line));
                resolve_symbol(&t.lines().collect::<Vec<_>>(), range, *start_line, snapshot)
            }
            None => Resolution::whole(Status::Orphan),
        },
    }
}

/// Move the Note's Anchor to where it was found. Returns true if the Note
/// changed and should be saved. The snapshot is kept: only the Reader's
/// confirmation replaces it.
pub fn apply(note: &mut Note, res: &Resolution) -> bool {
    match (res.start_line, res.end_line, note.anchor.lines()) {
        (Some(s), Some(e), Some(old)) if old != (s, e) => {
            note.anchor.set_lines(s, e);
            true
        }
        _ => false,
    }
}

fn trimmed<'a>(lines: impl IntoIterator<Item = &'a str>) -> Vec<&'a str> {
    lines.into_iter().map(str::trim).collect()
}

pub fn resolve_symbol(
    lines: &[&str],
    symbol_range: Option<(usize, usize)>,
    stored_start: usize,
    snapshot: &str,
) -> Resolution {
    if let Some((s, e)) = symbol_range
        && s >= 1
        && e >= s
        && e <= lines.len()
    {
        let now = trimmed(lines[s - 1..e].iter().copied());
        let status = if now != trimmed(snapshot.split('\n')) {
            Status::Drifted
        } else if s == stored_start {
            Status::Ok
        } else {
            Status::Moved
        };
        return Resolution::found(status, s - 1, e - 1);
    }
    resolve_range(lines, stored_start, snapshot)
}

pub fn resolve_range(lines: &[&str], stored_start: usize, snapshot: &str) -> Resolution {
    let snap = trimmed(snapshot.split('\n'));
    let file = trimmed(lines.iter().copied());
    let (k, n) = (snap.len(), file.len());
    let want = stored_start.saturating_sub(1);

    if want + k <= n && file[want..want + k] == snap[..] {
        return Resolution::found(Status::Ok, want, want + k - 1);
    }
    if k <= n {
        let best = (0..=n - k)
            .filter(|&i| file[i..i + k] == snap[..])
            .min_by_key(|&i| i.abs_diff(want));
        if let Some(i) = best {
            return Resolution::found(Status::Moved, i, i + k - 1);
        }
    }
    if let Some((s, e)) = fuzzy(&file, &snap, want) {
        return Resolution::found(Status::Drifted, s, e);
    }
    if k <= 2 && want + k <= n {
        let a = snap.join("\n");
        if !a.is_empty() && similarity(&a, &file[want..want + k].join("\n")) >= 0.6 {
            return Resolution::found(Status::Drifted, want, want + k - 1);
        }
    }
    Resolution::whole(Status::Orphan)
}

/// Vote for where the snapshot now starts. Each non-empty snapshot line that
/// appears in the file votes for `file_index - snapshot_index`, weighted by
/// 1/occurrences so a line like `}` barely counts. Votes within a small span
/// are pooled (lines inserted or deleted inside the range shift later votes).
/// The best pool wins if it covers at least half of the snapshot's non-empty
/// lines and carries at least the weight of one unique line.
fn fuzzy(file: &[&str], snap: &[&str], want: usize) -> Option<(usize, usize)> {
    let k = snap.len();
    let nonempty: Vec<usize> = (0..k).filter(|&i| !snap[i].is_empty()).collect();
    if nonempty.is_empty() || file.is_empty() {
        return None;
    }
    let mut occ: HashMap<&str, Vec<usize>> = HashMap::new();
    for (i, l) in file.iter().enumerate() {
        if !l.is_empty() {
            occ.entry(l).or_default().push(i);
        }
    }
    struct Vote {
        offset: isize,
        si: usize,
        fi: usize,
        w: f64,
    }
    let mut votes = Vec::new();
    for &si in &nonempty {
        if let Some(pos) = occ.get(snap[si]) {
            let w = 1.0 / pos.len() as f64;
            votes.extend(pos.iter().map(|&fi| Vote { offset: fi as isize - si as isize, si, fi, w }));
        }
    }
    if votes.is_empty() {
        return None;
    }
    votes.sort_by_key(|v| v.offset);

    let span = (k / 2).max(3) as isize;
    // (score, distance from the stored start, matched (si, fi) pairs)
    type Pool = (f64, usize, Vec<(usize, usize)>);
    let mut best: Option<Pool> = None;
    let mut b = 0;
    for a in 0..votes.len() {
        b = b.max(a);
        while b + 1 < votes.len() && votes[b + 1].offset - votes[a].offset <= span {
            b += 1;
        }
        let mut per_si: BTreeMap<usize, (usize, f64)> = BTreeMap::new();
        for v in &votes[a..=b] {
            per_si.entry(v.si).or_insert((v.fi, v.w));
        }
        let score: f64 = per_si.values().map(|x| x.1).sum();
        let pairs: Vec<(usize, usize)> = per_si.iter().map(|(&si, &(fi, _))| (si, fi)).collect();
        let dist = (pairs[0].1 as isize - pairs[0].0 as isize - want as isize).unsigned_abs();
        let better = match &best {
            None => true,
            Some((bs, bd, _)) => score > bs + 1e-9 || ((score - bs).abs() <= 1e-9 && dist < *bd),
        };
        if better {
            best = Some((score, dist, pairs));
        }
    }
    let (score, _, pairs) = best?;
    if (pairs.len() as f64) < 0.5 * nonempty.len() as f64 || score < 1.0 - 1e-9 {
        return None;
    }
    let (s0, f0) = pairs[0];
    let (s1, f1) = pairs[pairs.len() - 1];
    let start = f0.saturating_sub(s0);
    let end = (f1 + (k - 1 - s1)).min(file.len() - 1).max(start);
    Some((start, end))
}

/// Character-level similarity `2*LCS/(|a|+|b|)` in `[0, 1]`, on at most 300
/// characters of each side.
fn similarity(a: &str, b: &str) -> f64 {
    let a: Vec<char> = a.chars().take(300).collect();
    let b: Vec<char> = b.chars().take(300).collect();
    if a.is_empty() && b.is_empty() {
        return 1.0;
    }
    let mut prev = vec![0usize; b.len() + 1];
    let mut cur = vec![0usize; b.len() + 1];
    for ca in &a {
        for (j, cb) in b.iter().enumerate() {
            cur[j + 1] = if ca == cb { prev[j] + 1 } else { prev[j + 1].max(cur[j]) };
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    2.0 * prev[b.len()] as f64 / (a.len() + b.len()) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    const FILE: &str = "\
use std::io;

fn helper() -> u32 {
    42
}

fn login(user: &str) -> bool {
    let ok = check(user);
    log(ok);
    ok
}

fn main() {
    login(\"x\");
}";

    fn lines(s: &str) -> Vec<&str> {
        s.lines().collect()
    }

    fn login_snapshot() -> String {
        snapshot(FILE, 7, 11).unwrap()
    }

    #[test]
    fn snapshot_validates_range() {
        assert_eq!(snapshot(FILE, 4, 4).unwrap(), "    42");
        assert!(snapshot(FILE, 0, 1).is_err());
        assert!(snapshot(FILE, 5, 4).is_err());
        assert!(snapshot(FILE, 1, 99).is_err());
    }

    #[test]
    fn unchanged_is_ok() {
        let r = resolve_range(&lines(FILE), 7, &login_snapshot());
        assert_eq!(r, Resolution::found(Status::Ok, 6, 10));
    }

    #[test]
    fn reindent_is_not_drift() {
        let file = FILE.replace("    let ok", "        let ok");
        let r = resolve_range(&lines(&file), 7, &login_snapshot());
        assert_eq!(r.status, Status::Ok);
    }

    #[test]
    fn lines_added_above_is_moved() {
        let file = format!("// a\n// b\n// c\n{FILE}");
        let r = resolve_range(&lines(&file), 7, &login_snapshot());
        assert_eq!(r, Resolution::found(Status::Moved, 9, 13));
    }

    #[test]
    fn nearest_copy_wins() {
        let block = "a\nb\nc";
        let file = format!("{block}\nx\nx\nx\nx\nx\n{block}");
        assert_eq!(resolve_range(&lines(&file), 9, block).start_line, Some(9));
        assert_eq!(resolve_range(&lines(&file), 2, block).start_line, Some(1));
    }

    #[test]
    fn edited_inside_and_moved_is_drifted() {
        let file = format!("// a\n// b\n// c\n{}", FILE.replace("log(ok);", "audit(ok);"));
        let r = resolve_range(&lines(&file), 7, &login_snapshot());
        assert_eq!(r, Resolution::found(Status::Drifted, 9, 13));
    }

    #[test]
    fn line_inserted_inside_range_grows_it() {
        let file = FILE.replace("    log(ok);\n", "    log(ok);\n    metrics();\n");
        let r = resolve_range(&lines(&file), 7, &login_snapshot());
        assert_eq!(r, Resolution::found(Status::Drifted, 6, 11));
    }

    #[test]
    fn deleted_code_is_orphan() {
        let file = "use std::io;\n\nfn main() {}\n";
        let r = resolve_range(&lines(file), 7, &login_snapshot());
        assert_eq!(r.status, Status::Orphan);
        assert_eq!(r.start_line, None);
    }

    #[test]
    fn only_common_lines_left_is_orphan() {
        // `}` and `ok` survive, but they carry almost no weight.
        let file = "fn other() {\n    ok\n}\nfn more() {\n}\n";
        assert_eq!(resolve_range(&lines(file), 7, &login_snapshot()).status, Status::Orphan);
    }

    #[test]
    fn one_line_edited_in_place_is_drifted() {
        let snap = "    let ok = check(user);";
        let file = FILE.replace("check(user)", "check(user, true)");
        let r = resolve_range(&lines(&file), 8, snap);
        assert_eq!(r, Resolution::found(Status::Drifted, 7, 7));
        let file = FILE.replace("let ok = check(user);", "panic!();");
        assert_eq!(resolve_range(&lines(&file), 8, snap).status, Status::Orphan);
    }

    #[test]
    fn symbol_range_from_lua_wins() {
        let snap = login_snapshot();
        let l = lines(FILE);
        assert_eq!(resolve_symbol(&l, Some((7, 11)), 7, &snap).status, Status::Ok);
        let file = format!("\n\n{FILE}");
        assert_eq!(
            resolve_symbol(&lines(&file), Some((9, 13)), 7, &snap),
            Resolution::found(Status::Moved, 8, 12)
        );
        let file = FILE.replace("log(ok);", "audit(ok);");
        assert_eq!(resolve_symbol(&lines(&file), Some((7, 11)), 7, &snap).status, Status::Drifted);
        // Out-of-range input from Lua falls back to text matching.
        assert_eq!(resolve_symbol(&l, Some((7, 999)), 7, &snap).status, Status::Ok);
        assert_eq!(resolve_symbol(&l, None, 7, &snap).status, Status::Ok);
    }

    #[test]
    fn apply_moves_lines_but_keeps_snapshot() {
        let snap = login_snapshot();
        let mut note = Note {
            id: "x".into(),
            created: String::new(),
            updated: String::new(),
            anchor: Anchor::Range { path: "a".into(), start_line: 7, end_line: 11, snapshot: snap.clone() },
            body: String::new(),
        };
        let file = format!("\n{FILE}");
        let r = resolve_note(&note, Some(&file), &[]);
        assert!(apply(&mut note, &r));
        assert_eq!(note.anchor.lines(), Some((8, 12)));
        assert!(!apply(&mut note, &r));
        assert!(matches!(&note.anchor, Anchor::Range { snapshot, .. } if *snapshot == snap));
    }

    #[test]
    fn file_and_project_anchors() {
        let mut note = Note {
            id: "x".into(),
            created: String::new(),
            updated: String::new(),
            anchor: Anchor::File { path: "a".into() },
            body: String::new(),
        };
        assert_eq!(resolve_note(&note, Some(""), &[]).status, Status::Ok);
        assert_eq!(resolve_note(&note, None, &[]).status, Status::Orphan);
        note.anchor = Anchor::Project;
        assert_eq!(resolve_note(&note, None, &[]).status, Status::Ok);
    }

    #[test]
    fn similarity_bounds() {
        assert_eq!(similarity("abc", "abc"), 1.0);
        assert_eq!(similarity("abc", "xyz"), 0.0);
        assert!(similarity("let x = 1", "let x = 2") > 0.8);
    }
}
