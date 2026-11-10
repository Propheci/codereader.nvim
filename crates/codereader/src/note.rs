//! The Note and its Anchor, and the Markdown file format they are stored in.
//!
//! A Note file is Markdown with a frontmatter block. The frontmatter is
//! pretty-printed JSON, which is valid YAML, so Obsidian and other tools still
//! read it as properties without this crate needing a YAML dependency:
//!
//! ```text
//! ---
//! {
//!   "id": "20261110-142233-1a2b",
//!   "kind": "range",
//!   "path": "src/auth.rs",
//!   ...
//! }
//! ---
//! This is not the real login, see #lie
//! ```

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// The thing in the Project that a Note is attached to.
///
/// Line numbers are 1-based and inclusive. `snapshot` is the anchored code as
/// it was when the Reader wrote or last confirmed the Note; it is what lets the
/// Anchor be found again after Drift, and what tells a Drifted Note apart.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Anchor {
    Range {
        path: String,
        start_line: usize,
        end_line: usize,
        snapshot: String,
    },
    Symbol {
        path: String,
        /// Container path from the outside in, e.g. `["UserService", "login"]`.
        symbol: Vec<String>,
        start_line: usize,
        end_line: usize,
        snapshot: String,
    },
    File {
        path: String,
    },
    Project,
}

impl Anchor {
    /// The stored path (relative to the Project root when inside it).
    pub fn path(&self) -> Option<&str> {
        match self {
            Anchor::Range { path, .. } | Anchor::Symbol { path, .. } | Anchor::File { path } => {
                Some(path)
            }
            Anchor::Project => None,
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Anchor::Range { .. } => "range",
            Anchor::Symbol { .. } => "symbol",
            Anchor::File { .. } => "file",
            Anchor::Project => "project",
        }
    }

    pub fn lines(&self) -> Option<(usize, usize)> {
        match self {
            Anchor::Range { start_line, end_line, .. }
            | Anchor::Symbol { start_line, end_line, .. } => Some((*start_line, *end_line)),
            _ => None,
        }
    }

    pub fn set_lines(&mut self, start: usize, end: usize) {
        if let Anchor::Range { start_line, end_line, .. }
        | Anchor::Symbol { start_line, end_line, .. } = self
        {
            *start_line = start;
            *end_line = end;
        }
    }

    pub fn set_snapshot(&mut self, text: String) {
        if let Anchor::Range { snapshot, .. } | Anchor::Symbol { snapshot, .. } = self {
            *snapshot = text;
        }
    }

    /// Short human form: `src/a.rs:10-12`, `src/a.rs:10 (A > b)`, `src/a.rs`, `(project)`.
    pub fn describe(&self) -> String {
        fn lines(s: usize, e: usize) -> String {
            if s == e { format!("{s}") } else { format!("{s}-{e}") }
        }
        match self {
            Anchor::Range { path, start_line, end_line, .. } => {
                format!("{path}:{}", lines(*start_line, *end_line))
            }
            Anchor::Symbol { path, symbol, start_line, end_line, .. } => {
                format!("{path}:{} ({})", lines(*start_line, *end_line), symbol.join(" > "))
            }
            Anchor::File { path } => path.clone(),
            Anchor::Project => "(project)".to_string(),
        }
    }
}

/// A short text that the Reader writes about the code.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Note {
    pub id: String,
    pub created: String,
    /// Last time the Reader changed the Note (body, Anchor or confirmation).
    /// Re-finding a moved Anchor does not bump it.
    pub updated: String,
    #[serde(flatten)]
    pub anchor: Anchor,
    /// Markdown; the first non-empty line is the title. Never ends in a newline.
    #[serde(skip)]
    pub body: String,
}

impl Note {
    /// First non-empty line of the body, without leading `#` heading marks.
    pub fn title(&self) -> String {
        self.body
            .lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .map(|l| l.trim_start_matches('#').trim().to_string())
            .unwrap_or_default()
    }

    /// Free `#tags` in the body, in order of first appearance. A tag is `#`
    /// at the start of a word followed by letters, digits, `_`, `-` or `/`
    /// (not all digits, so `#123` is not a tag). Fenced code is skipped.
    pub fn tags(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        let mut in_fence = false;
        for line in self.body.lines() {
            if line.trim_start().starts_with("```") {
                in_fence = !in_fence;
                continue;
            }
            if in_fence {
                continue;
            }
            let chars: Vec<char> = line.chars().collect();
            let mut i = 0;
            while i < chars.len() {
                if chars[i] == '#' && (i == 0 || chars[i - 1].is_whitespace()) {
                    let mut j = i + 1;
                    while j < chars.len()
                        && (chars[j].is_alphanumeric() || matches!(chars[j], '_' | '-' | '/'))
                    {
                        j += 1;
                    }
                    if j > i + 1 {
                        let tag: String = chars[i + 1..j].iter().collect();
                        if !tag.chars().all(|c| c.is_ascii_digit()) && !out.contains(&tag) {
                            out.push(tag);
                        }
                    }
                    i = j;
                } else {
                    i += 1;
                }
            }
        }
        out
    }

    pub fn has_tag(&self, tag: &str) -> bool {
        let tag = tag.trim_start_matches('#');
        self.tags().iter().any(|t| t.eq_ignore_ascii_case(tag))
    }

    pub fn to_markdown(&self) -> Result<String> {
        let meta = serde_json::to_string_pretty(self)?;
        Ok(format!("---\n{meta}\n---\n{}\n", self.body))
    }

    pub fn from_markdown(text: &str) -> Result<Note> {
        let text = text.replace("\r\n", "\n");
        let rest = text.strip_prefix("---\n").context("missing frontmatter")?;
        // JSON escapes newlines inside strings, so a bare `---` line can only
        // be the closing fence.
        let (meta, body) = match rest.find("\n---\n") {
            Some(i) => (&rest[..i], &rest[i + 5..]),
            None => (
                rest.strip_suffix("\n---").context("unterminated frontmatter")?,
                "",
            ),
        };
        let mut note: Note = serde_json::from_str(meta).context("invalid frontmatter")?;
        note.body = normalize_body(body);
        Ok(note)
    }
}

/// Bodies are stored without trailing whitespace/newlines.
pub fn normalize_body(body: &str) -> String {
    body.trim_end().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(anchor: Anchor, body: &str) -> Note {
        Note {
            id: "20261110-120000-abcd".into(),
            created: "2026-11-10T12:00:00+05:30".into(),
            updated: "2026-11-10T12:00:00+05:30".into(),
            anchor,
            body: body.into(),
        }
    }

    #[test]
    fn round_trips_every_anchor_kind() {
        let anchors = [
            Anchor::Range {
                path: "src/a.rs".into(),
                start_line: 3,
                end_line: 5,
                snapshot: "fn a() {\n    1\n}".into(),
            },
            Anchor::Symbol {
                path: "src/a.rs".into(),
                symbol: vec!["Svc".into(), "login".into()],
                start_line: 10,
                end_line: 20,
                snapshot: "fn login()\n---\n".into(),
            },
            Anchor::File { path: "/abs/lib.rs".into() },
            Anchor::Project,
        ];
        for a in anchors {
            let n = note(a, "Title line\n\nmore *markdown*\n---\nafter a rule");
            let md = n.to_markdown().unwrap();
            assert_eq!(Note::from_markdown(&md).unwrap(), n, "{md}");
        }
    }

    #[test]
    fn frontmatter_is_flat_for_obsidian() {
        let md = note(Anchor::File { path: "x".into() }, "hi").to_markdown().unwrap();
        assert!(md.starts_with("---\n{\n"));
        assert!(md.contains("\"kind\": \"file\""));
        assert!(md.contains("\"path\": \"x\""));
        assert!(md.ends_with("---\nhi\n"));
    }

    #[test]
    fn empty_body_round_trips() {
        let n = note(Anchor::Project, "");
        assert_eq!(Note::from_markdown(&n.to_markdown().unwrap()).unwrap(), n);
    }

    #[test]
    fn title_skips_blank_lines_and_heading_marks() {
        assert_eq!(note(Anchor::Project, "\n\n## Why  \nbody").title(), "Why");
    }

    #[test]
    fn tags() {
        let n = note(
            Anchor::Project,
            "# heading is not a tag\nfoo #question and #bug/auth, #question again\nissue #123\n```\n#not-in-code\n```\nx#nope #lie",
        );
        assert_eq!(n.tags(), vec!["question", "bug/auth", "lie"]);
        assert!(n.has_tag("#Question"));
        assert!(!n.has_tag("not-in-code"));
    }
}
