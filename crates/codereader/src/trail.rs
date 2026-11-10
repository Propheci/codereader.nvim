//! Trails: a tree of Stops recording the Reader's path through the code.
//!
//! One JSON file per Trail under `<store_dir>/trails/`. Every change runs as a
//! locked read-modify-write, because two Neovim instances on one Project may
//! touch the same Trail.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::fsutil::{FileLock, write_atomic};
use crate::ids;
use crate::resolve::{self, Status};

/// One code location on a Trail.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stop {
    /// `s1`, `s2`, ... unique within its Trail.
    pub id: String,
    /// `None` for a root Stop. A Stop with several children is a branch point.
    pub parent: Option<String>,
    pub path: String,
    /// 1-based.
    pub line: usize,
    /// 1-based.
    pub col: usize,
    /// The text of the line when the Stop was recorded; used to find the
    /// Stop again after Drift.
    pub snapshot: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub symbol: Vec<String>,
    /// How the Reader got here: `definition`, `references`, `manual`,
    /// `origin` (the place a jump started from), ...
    pub via: String,
    pub created: String,
    /// Logical clock of the last visit; `forward` follows the most recently
    /// visited child at a branch point.
    pub visited: u64,
}

/// A location to record as a Stop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Location {
    pub path: String,
    pub line: usize,
    pub col: usize,
    pub snapshot: String,
    pub symbol: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Trail {
    pub id: String,
    /// `None` for the unnamed Trail made automatically.
    pub name: Option<String>,
    pub created: String,
    pub updated: String,
    pub current: Option<String>,
    pub clock: u64,
    pub next_stop: u64,
    pub stops: Vec<Stop>,
}

impl Trail {
    pub fn new(id: String, name: Option<String>) -> Trail {
        let now = ids::now();
        Trail { id, name, created: now.clone(), updated: now, current: None, clock: 0, next_stop: 1, stops: vec![] }
    }

    pub fn stop(&self, id: &str) -> Option<&Stop> {
        self.stops.iter().find(|s| s.id == id)
    }

    fn stop_mut(&mut self, id: &str) -> Option<&mut Stop> {
        self.stops.iter_mut().find(|s| s.id == id)
    }

    pub fn current_stop(&self) -> Option<&Stop> {
        self.current.as_deref().and_then(|id| self.stop(id))
    }

    pub fn children(&self, id: &str) -> Vec<&Stop> {
        self.stops.iter().filter(|s| s.parent.as_deref() == Some(id)).collect()
    }

    fn at(stop: &Stop, loc: &Location) -> bool {
        stop.path == loc.path && stop.line == loc.line
    }

    fn visit(&mut self, id: &str) {
        self.clock += 1;
        let clock = self.clock;
        if let Some(s) = self.stop_mut(id) {
            s.visited = clock;
        }
        self.current = Some(id.to_string());
    }

    /// The child of `parent` at `loc`, creating it if there is none (so the
    /// same jump twice does not make a duplicate branch).
    fn child_at(&mut self, parent: Option<String>, loc: Location, via: &str) -> String {
        if let Some(s) = self.stops.iter().find(|s| s.parent == parent && Self::at(s, &loc)) {
            return s.id.clone();
        }
        let id = format!("s{}", self.next_stop);
        self.next_stop += 1;
        self.stops.push(Stop {
            id: id.clone(),
            parent,
            path: loc.path,
            line: loc.line,
            col: loc.col,
            snapshot: loc.snapshot,
            symbol: loc.symbol,
            via: via.to_string(),
            created: ids::now(),
            visited: 0,
        });
        id
    }

    /// Record a move to `to`. With `from` (an LSP jump), the place the jump
    /// started is first recorded under the current Stop unless the Reader is
    /// still on it. Pushing after going `back` creates a branch.
    pub fn push(&mut self, from: Option<Location>, to: Location, via: &str) -> String {
        if let Some(from) = from
            && !self.current_stop().is_some_and(|c| Self::at(c, &from))
        {
            let id = self.child_at(self.current.clone(), from, "origin");
            self.visit(&id);
        }
        if let Some(c) = self.current_stop()
            && Self::at(c, &to)
        {
            let id = c.id.clone();
            self.visit(&id);
            return id;
        }
        let id = self.child_at(self.current.clone(), to, via);
        self.visit(&id);
        id
    }

    pub fn back(&mut self) -> Result<String> {
        let parent = self.current_stop().context("trail has no current stop")?.parent.clone();
        let id = parent.context("already at the start of the trail")?;
        self.visit(&id);
        Ok(id)
    }

    pub fn forward(&mut self) -> Result<String> {
        let cur = self.current.clone().context("trail has no current stop")?;
        let next = self
            .children(&cur)
            .into_iter()
            .max_by_key(|s| (s.visited, std::cmp::Reverse(s.id.clone())))
            .map(|s| s.id.clone())
            .context("already at the end of this branch")?;
        self.visit(&next);
        Ok(next)
    }

    pub fn goto(&mut self, id: &str) -> Result<()> {
        if self.stop(id).is_none() {
            bail!("no stop {id} in trail {}", self.id);
        }
        self.visit(id);
        Ok(())
    }
}

/// Where a Stop is now. `lost` means it can no longer be found.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum StopStatus {
    Ok,
    Moved,
    Lost,
}

/// Find a Stop again in `text` (the current file content, if readable).
/// A one-line edit in place still counts as found: unlike a Note, a Stop
/// holds nothing the Reader wrote, so there is no "Drifted" for it.
pub fn resolve_stop(stop: &Stop, text: Option<&str>) -> (StopStatus, usize) {
    let Some(text) = text else { return (StopStatus::Lost, stop.line) };
    let lines: Vec<&str> = text.lines().collect();
    let r = resolve::resolve_range(&lines, stop.line, &stop.snapshot);
    match (r.status, r.start_line) {
        (Status::Orphan, _) | (_, None) => (StopStatus::Lost, stop.line),
        (_, Some(l)) if l == stop.line => (StopStatus::Ok, l),
        (_, Some(l)) => (StopStatus::Moved, l),
    }
}

pub struct TrailStore {
    dir: PathBuf,
}

impl TrailStore {
    pub fn new(store_dir: &Path) -> Self {
        Self { dir: store_dir.join("trails") }
    }

    fn file(&self, id: &str) -> Result<PathBuf> {
        if !ids::is_valid(id) {
            bail!("invalid trail id: {id:?}");
        }
        Ok(self.dir.join(format!("{id}.json")))
    }

    fn lock(&self, id: &str) -> Result<FileLock> {
        FileLock::acquire(&self.dir.join(format!(".{id}.lock")))
    }

    fn read(&self, id: &str) -> Result<Trail> {
        let path = self.file(id)?;
        let text = fs::read_to_string(&path).with_context(|| format!("no trail {id}"))?;
        serde_json::from_str(&text).with_context(|| format!("parse {}", path.display()))
    }

    fn write(&self, t: &Trail) -> Result<()> {
        write_atomic(&self.file(&t.id)?, serde_json::to_string_pretty(t)?.as_bytes())
    }

    pub fn create(&self, name: Option<String>) -> Result<Trail> {
        let mut id = ids::new_id();
        while self.file(&id)?.exists() {
            id = ids::new_id();
        }
        let t = Trail::new(id, name);
        self.write(&t)?;
        Ok(t)
    }

    pub fn get(&self, id: &str) -> Result<Trail> {
        self.read(id)
    }

    /// Locked read-modify-write. `updated` is bumped after `f` succeeds.
    pub fn update<T>(&self, id: &str, f: impl FnOnce(&mut Trail) -> Result<T>) -> Result<(Trail, T)> {
        let _lock = self.lock(id)?;
        let mut t = self.read(id)?;
        let out = f(&mut t)?;
        t.updated = ids::now();
        self.write(&t)?;
        Ok((t, out))
    }

    /// All Trails, most recently updated first.
    pub fn list(&self) -> Result<(Vec<Trail>, Vec<String>)> {
        let mut out = Vec::new();
        let mut warnings = Vec::new();
        let entries = match fs::read_dir(&self.dir) {
            Ok(e) => e,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((out, warnings)),
            Err(e) => return Err(e).with_context(|| format!("read {}", self.dir.display())),
        };
        for entry in entries {
            let path = entry?.path();
            let Some(id) = path.file_name().and_then(|n| n.to_str()).and_then(|n| n.strip_suffix(".json"))
            else {
                continue;
            };
            if id.starts_with('.') {
                continue;
            }
            match self.read(id) {
                Ok(t) => out.push(t),
                Err(e) => warnings.push(format!("{e:#}")),
            }
        }
        out.sort_by(|a, b| (&b.updated, &b.id).cmp(&(&a.updated, &a.id)));
        Ok((out, warnings))
    }

    pub fn delete(&self, id: &str) -> Result<()> {
        let _lock = self.lock(id)?;
        fs::remove_file(self.file(id)?).with_context(|| format!("no trail {id}"))?;
        let _ = fs::remove_file(self.dir.join(format!(".{id}.lock")));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loc(path: &str, line: usize) -> Location {
        Location { path: path.into(), line, col: 1, snapshot: format!("line {line}"), symbol: vec![] }
    }

    fn ids_of(stops: &[&Stop]) -> Vec<String> {
        stops.iter().map(|s| s.id.clone()).collect()
    }

    #[test]
    fn jump_records_origin_then_target() {
        let mut t = Trail::new("t".into(), None);
        let b = t.push(Some(loc("a", 1)), loc("b", 2), "definition");
        assert_eq!(t.stops.len(), 2);
        assert_eq!(t.stop(&b).unwrap().parent.as_deref(), Some("s1"));
        assert_eq!(t.stop("s1").unwrap().via, "origin");
        // Jumping on from where we are does not re-record the origin.
        let c = t.push(Some(loc("b", 2)), loc("c", 3), "definition");
        assert_eq!(t.stop(&c).unwrap().parent, Some(b));
        assert_eq!(t.stops.len(), 3);
    }

    #[test]
    fn push_to_current_location_is_a_no_op() {
        let mut t = Trail::new("t".into(), None);
        t.push(None, loc("a", 1), "manual");
        t.push(None, loc("a", 1), "manual");
        assert_eq!(t.stops.len(), 1);
    }

    #[test]
    fn going_back_then_jumping_elsewhere_branches() {
        // A -> B -> C -> D, back to B, jump to E.
        let mut t = Trail::new("t".into(), None);
        for (p, l) in [("a", 1), ("b", 1), ("c", 1), ("d", 1)] {
            t.push(None, loc(p, l), "definition");
        }
        t.back().unwrap();
        t.back().unwrap();
        assert_eq!(t.current_stop().unwrap().path, "b");
        t.push(None, loc("e", 1), "definition");
        let b = t.stops.iter().find(|s| s.path == "b").unwrap().id.clone();
        assert_eq!(ids_of(&t.children(&b)), vec!["s3", "s5"]);
        assert_eq!(t.stops.len(), 5, "C and D are kept");
    }

    #[test]
    fn forward_follows_most_recent_branch() {
        let mut t = Trail::new("t".into(), None);
        t.push(None, loc("a", 1), "manual");
        t.push(None, loc("b", 1), "definition"); // s2
        t.back().unwrap();
        t.push(None, loc("c", 1), "definition"); // s3
        t.back().unwrap();
        assert_eq!(t.forward().unwrap(), "s3");
        t.goto("s2").unwrap();
        t.back().unwrap();
        assert_eq!(t.forward().unwrap(), "s2");
        assert!(t.forward().is_err());
        t.goto("s1").unwrap();
        assert!(t.back().is_err());
        assert!(t.goto("s99").is_err());
    }

    #[test]
    fn repeating_a_jump_reuses_the_branch() {
        let mut t = Trail::new("t".into(), None);
        t.push(None, loc("a", 1), "manual");
        t.push(None, loc("b", 1), "definition");
        t.back().unwrap();
        t.push(None, loc("b", 1), "definition");
        assert_eq!(t.stops.len(), 2);
    }

    #[test]
    fn resolve_stop_follows_the_line() {
        let stop = Stop {
            id: "s1".into(),
            parent: None,
            path: "a".into(),
            line: 2,
            col: 1,
            snapshot: "    let ok = check(user);".into(),
            symbol: vec![],
            via: "manual".into(),
            created: String::new(),
            visited: 0,
        };
        let text = "fn x() {\n    let ok = check(user);\n}";
        assert_eq!(resolve_stop(&stop, Some(text)), (StopStatus::Ok, 2));
        assert_eq!(resolve_stop(&stop, Some(&format!("\n\n{text}"))), (StopStatus::Moved, 4));
        let edited = text.replace("check(user)", "check(user, true)");
        assert_eq!(resolve_stop(&stop, Some(&edited)), (StopStatus::Ok, 2));
        assert_eq!(resolve_stop(&stop, Some("nothing here")), (StopStatus::Lost, 2));
        assert_eq!(resolve_stop(&stop, None), (StopStatus::Lost, 2));
    }

    #[test]
    fn store_round_trip_and_locked_update() {
        let d = tempfile::tempdir().unwrap();
        let s = TrailStore::new(d.path());
        let t = s.create(Some("login".into())).unwrap();
        let (t2, id) = s.update(&t.id, |t| Ok(t.push(None, loc("a", 1), "manual"))).unwrap();
        assert_eq!(id, "s1");
        assert_eq!(s.get(&t.id).unwrap(), t2);
        assert!(s.update(&t.id, |t| t.back()).is_err());
        assert_eq!(s.get(&t.id).unwrap().stops.len(), 1, "failed update writes nothing");
        let (all, w) = s.list().unwrap();
        assert!(w.is_empty());
        assert_eq!(all.len(), 1);
        s.delete(&t.id).unwrap();
        assert!(s.list().unwrap().0.is_empty());
    }
}
