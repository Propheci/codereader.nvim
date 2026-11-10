//! Project identity and where its Notes and Trails are stored.

use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result};
use serde::Serialize;

#[derive(Debug, Clone, Default)]
pub struct ProjectOptions {
    /// Directory discovery starts from (normally the process cwd).
    pub cwd: PathBuf,
    /// Explicit Project root; skips git discovery.
    pub root: Option<PathBuf>,
    /// Fixed Project name; overrides the name derived from the root path.
    pub name: Option<String>,
    /// Base directory for out-of-repo storage.
    pub data_dir: Option<PathBuf>,
    /// Store under `<root>/.codereader/` instead of `data_dir`.
    pub in_repo: bool,
}

/// The codebase that a set of Notes and Trails belongs to.
#[derive(Debug, Clone, Serialize)]
pub struct Project {
    pub name: String,
    pub root: PathBuf,
    pub store_dir: PathBuf,
}

impl Project {
    /// Root = explicit `root`, else the nearest ancestor of `cwd` holding
    /// `.git` (a directory, or a file for worktrees), else `cwd`.
    pub fn discover(opts: ProjectOptions) -> Result<Project> {
        let cwd = canonical(&opts.cwd);
        let root = match &opts.root {
            Some(r) => canonical(&join(&cwd, r)),
            None => find_git_root(&cwd).unwrap_or_else(|| cwd.clone()),
        };
        let name = opts.name.clone().unwrap_or_else(|| default_name(&root));
        let store_dir = if opts.in_repo {
            root.join(".codereader")
        } else {
            let base = match opts.data_dir {
                Some(d) => join(&cwd, &d),
                None => default_data_dir().context("cannot find a data directory; pass --data-dir")?,
            };
            base.join(sanitize(&name))
        };
        Ok(Project { name, root, store_dir })
    }

    /// Absolute, canonical form of a user-given path (relative to `cwd`).
    pub fn absolutize(&self, cwd: &Path, p: &Path) -> PathBuf {
        canonical(&join(cwd, p))
    }

    /// The form stored in an Anchor: relative to the root with `/` separators
    /// when inside the Project, else absolute (code outside the Project, e.g.
    /// a dependency, still belongs to this Project's Notes).
    pub fn to_stored(&self, abs: &Path) -> String {
        match abs.strip_prefix(&self.root) {
            Ok(rel) if !rel.as_os_str().is_empty() => rel
                .components()
                .map(|c| c.as_os_str().to_string_lossy())
                .collect::<Vec<_>>()
                .join("/"),
            _ => abs.to_string_lossy().into_owned(),
        }
    }

    pub fn to_abs(&self, stored: &str) -> PathBuf {
        let p = Path::new(stored);
        if p.is_absolute() { p.to_path_buf() } else { self.root.join(p) }
    }
}

fn join(base: &Path, p: &Path) -> PathBuf {
    if p.is_absolute() { p.to_path_buf() } else { base.join(p) }
}

/// Canonicalize when the path exists (resolves symlinks such as macOS
/// `/tmp` -> `/private/tmp`), else fold `.`/`..` lexically.
fn canonical(p: &Path) -> PathBuf {
    if let Ok(c) = p.canonicalize() {
        return c;
    }
    let mut lexical = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                lexical.pop();
            }
            Component::CurDir => {}
            other => lexical.push(other.as_os_str()),
        }
    }
    // Canonicalize the deepest existing ancestor, then append the rest, so a
    // deleted file under a symlinked dir still compares equal to the root.
    for anc in lexical.ancestors().skip(1) {
        if let Ok(c) = anc.canonicalize() {
            return match lexical.strip_prefix(anc) {
                Ok(rest) => c.join(rest),
                Err(_) => lexical,
            };
        }
    }
    lexical
}

pub fn find_git_root(start: &Path) -> Option<PathBuf> {
    start.ancestors().find(|d| d.join(".git").exists()).map(Path::to_path_buf)
}

/// `$XDG_DATA_HOME/nvim/codereader`, else `~/.local/share/nvim/codereader`
/// (matches Neovim's `stdpath("data")` on Linux and macOS).
fn default_data_dir() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_DATA_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))?;
    Some(base.join("nvim").join("codereader"))
}

/// `<basename>-<8 hex of the full path>`: readable, and unique per checkout.
fn default_name(root: &Path) -> String {
    let base = root
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "root".to_string());
    format!("{base}-{:08x}", fnv1a(root.to_string_lossy().as_bytes()) as u32)
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

fn sanitize(name: &str) -> String {
    let s: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '-' })
        .collect();
    if s.is_empty() || s.chars().all(|c| c == '.') { "project".into() } else { s }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn opts(cwd: &Path, data: &Path) -> ProjectOptions {
        ProjectOptions { cwd: cwd.into(), data_dir: Some(data.into()), ..Default::default() }
    }

    #[test]
    fn finds_git_root_from_subdir() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().join("repo");
        fs::create_dir_all(root.join(".git")).unwrap();
        fs::create_dir_all(root.join("src/deep")).unwrap();
        let p = Project::discover(opts(&root.join("src/deep"), t.path())).unwrap();
        assert_eq!(p.root, root.canonicalize().unwrap());
        assert!(p.name.starts_with("repo-"), "{}", p.name);
        assert_eq!(p.store_dir, t.path().join(&p.name));
    }

    #[test]
    fn falls_back_to_cwd_and_respects_overrides() {
        let t = tempfile::tempdir().unwrap();
        let p = Project::discover(ProjectOptions {
            name: Some("my proj".into()),
            in_repo: true,
            ..opts(t.path(), t.path())
        })
        .unwrap();
        assert_eq!(p.root, t.path().canonicalize().unwrap());
        assert_eq!(p.name, "my proj");
        assert_eq!(p.store_dir, p.root.join(".codereader"));
        let p = Project::discover(ProjectOptions { name: Some("my proj".into()), ..opts(t.path(), t.path()) })
            .unwrap();
        assert!(p.store_dir.ends_with("my-proj"));
    }

    #[test]
    fn stored_paths_are_relative_inside_absolute_outside() {
        let t = tempfile::tempdir().unwrap();
        fs::create_dir_all(t.path().join("src")).unwrap();
        fs::write(t.path().join("src/a.rs"), "").unwrap();
        let p = Project::discover(opts(t.path(), t.path())).unwrap();
        let a = p.absolutize(t.path(), Path::new("src/./a.rs"));
        assert_eq!(p.to_stored(&a), "src/a.rs");
        assert_eq!(p.to_abs("src/a.rs"), a);
        assert_eq!(p.to_stored(Path::new("/usr/lib/x.go")), "/usr/lib/x.go");
        assert_eq!(p.to_abs("/usr/lib/x.go"), PathBuf::from("/usr/lib/x.go"));
    }
}
