//! The Note store: one Markdown file per Note under `<store_dir>/notes/`.
//! See `docs/adr/0001-notes-outside-repo-as-markdown.md`.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::fsutil::write_atomic;
use crate::ids;
use crate::note::{Anchor, Note, normalize_body};

pub struct NoteStore {
    dir: PathBuf,
}

impl NoteStore {
    pub fn new(store_dir: &Path) -> Self {
        Self { dir: store_dir.join("notes") }
    }

    fn file(&self, id: &str) -> Result<PathBuf> {
        if !ids::is_valid(id) {
            bail!("invalid note id: {id:?}");
        }
        Ok(self.dir.join(format!("{id}.md")))
    }

    /// All Notes, oldest first. Files that do not parse are skipped and
    /// reported as warnings rather than failing the whole listing.
    pub fn list(&self) -> Result<(Vec<Note>, Vec<String>)> {
        let mut notes = Vec::new();
        let mut warnings = Vec::new();
        let entries = match fs::read_dir(&self.dir) {
            Ok(e) => e,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((notes, warnings)),
            Err(e) => return Err(e).with_context(|| format!("read {}", self.dir.display())),
        };
        for entry in entries {
            let path = entry?.path();
            if path.extension().is_none_or(|e| e != "md") {
                continue;
            }
            match fs::read_to_string(&path).map_err(anyhow::Error::from).and_then(|t| Note::from_markdown(&t)) {
                Ok(n) => notes.push(n),
                Err(e) => warnings.push(format!("{}: {e:#}", path.display())),
            }
        }
        notes.sort_by(|a, b| (&a.created, &a.id).cmp(&(&b.created, &b.id)));
        Ok((notes, warnings))
    }

    pub fn get(&self, id: &str) -> Result<Note> {
        let path = self.file(id)?;
        let text = fs::read_to_string(&path).with_context(|| format!("no note {id}"))?;
        Note::from_markdown(&text).with_context(|| format!("parse {}", path.display()))
    }

    pub fn save(&self, note: &Note) -> Result<()> {
        write_atomic(&self.file(&note.id)?, note.to_markdown()?.as_bytes())
    }

    pub fn create(&self, anchor: Anchor, body: &str) -> Result<Note> {
        let mut id = ids::new_id();
        while self.file(&id)?.exists() {
            id = ids::new_id();
        }
        let now = ids::now();
        let note = Note { id, created: now.clone(), updated: now, anchor, body: normalize_body(body) };
        self.save(&note)?;
        Ok(note)
    }

    pub fn delete(&self, id: &str) -> Result<()> {
        fs::remove_file(self.file(id)?).with_context(|| format!("no note {id}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_get_list_delete() {
        let t = tempfile::tempdir().unwrap();
        let s = NoteStore::new(t.path());
        assert!(s.list().unwrap().0.is_empty());
        let a = s.create(Anchor::Project, "first\n\n").unwrap();
        let b = s.create(Anchor::File { path: "x".into() }, "second").unwrap();
        assert_ne!(a.id, b.id);
        assert_eq!(s.get(&a.id).unwrap().body, "first");
        fs::write(t.path().join("notes/broken.md"), "no frontmatter").unwrap();
        let (all, warnings) = s.list().unwrap();
        // Same-second Notes order by their random id suffix, so compare sets.
        let mut got: Vec<String> = all.iter().map(|n| n.id.clone()).collect();
        let mut want = vec![a.id.clone(), b.id];
        got.sort();
        want.sort();
        assert_eq!(got, want);
        assert_eq!(warnings.len(), 1);
        s.delete(&a.id).unwrap();
        assert!(s.get(&a.id).is_err());
    }

    #[test]
    fn rejects_path_traversal_ids() {
        let t = tempfile::tempdir().unwrap();
        assert!(NoteStore::new(t.path()).get("../../etc/passwd").is_err());
    }
}
