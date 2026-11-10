//! End-to-end tests of the `codereader` binary and its JSON contract, which
//! the Lua plugin depends on.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde_json::Value;

struct Env {
    _tmp: tempfile::TempDir,
    repo: PathBuf,
    data: PathBuf,
}

const AUTH: &str = "\
use std::io;

fn login(user: &str) -> bool {
    let ok = check(user);
    log(ok);
    ok
}
";

fn env() -> Env {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("repo");
    fs::create_dir_all(repo.join(".git")).unwrap();
    fs::create_dir_all(repo.join("src")).unwrap();
    fs::write(repo.join("src/auth.rs"), AUTH).unwrap();
    let data = tmp.path().join("data");
    Env { repo, data, _tmp: tmp }
}

impl Env {
    fn run_raw(&self, args: &[&str], stdin: Option<&str>) -> (bool, Value) {
        let mut child = Command::new(env!("CARGO_BIN_EXE_codereader"))
            .current_dir(&self.repo)
            .arg("--json")
            .arg("--data-dir")
            .arg(&self.data)
            .args(args)
            .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        if let Some(s) = stdin {
            child.stdin.take().unwrap().write_all(s.as_bytes()).unwrap();
        }
        let out = child.wait_with_output().unwrap();
        let stdout = String::from_utf8(out.stdout).unwrap();
        let v: Value = serde_json::from_str(&stdout)
            .unwrap_or_else(|e| panic!("{args:?}: bad JSON ({e}): {stdout}\n{}", String::from_utf8_lossy(&out.stderr)));
        assert_eq!(v["schema_version"], 1);
        assert_eq!(v["ok"].as_bool().unwrap(), out.status.success(), "{v}");
        (out.status.success(), v)
    }

    fn ok(&self, args: &[&str]) -> Value {
        self.ok_in(args, None)
    }

    fn ok_in(&self, args: &[&str], stdin: Option<&str>) -> Value {
        let (ok, v) = self.run_raw(args, stdin);
        assert!(ok, "{args:?} failed: {v}");
        v["data"].clone()
    }

    fn err(&self, args: &[&str]) -> String {
        let (ok, v) = self.run_raw(args, None);
        assert!(!ok, "{args:?} should fail: {v}");
        v["error"].as_str().unwrap().to_string()
    }

    fn edit(&self, rel: &str, f: impl FnOnce(&str) -> String) {
        let p = self.repo.join(rel);
        let s = fs::read_to_string(&p).unwrap();
        fs::write(&p, f(&s)).unwrap();
    }
}

fn store_dir(e: &Env) -> PathBuf {
    PathBuf::from(e.ok(&["project"])["store_dir"].as_str().unwrap())
}

#[test]
fn project_is_the_git_root_and_stored_outside_the_repo() {
    let e = env();
    let p = e.ok(&["project"]);
    assert_eq!(Path::new(p["root"].as_str().unwrap()), e.repo.canonicalize().unwrap());
    assert!(p["store_dir"].as_str().unwrap().starts_with(e.data.to_str().unwrap()));
}

#[test]
fn range_note_lifecycle_through_drift() {
    let e = env();
    let n = e.ok(&["note", "add", "--path", "src/auth.rs", "--start", "3", "--end", "7", "-m", "Fake login #lie\n\nreal one is elsewhere"]);
    let id = n["id"].as_str().unwrap().to_string();
    assert_eq!(n["kind"], "range");
    assert_eq!(n["path"], "src/auth.rs");
    assert_eq!(n["title"], "Fake login #lie");
    assert_eq!(n["tags"], serde_json::json!(["lie"]));
    assert!(n["abs_path"].as_str().unwrap().ends_with("src/auth.rs"));

    // The file is real Markdown on disk.
    let md = fs::read_to_string(store_dir(&e).join("notes").join(format!("{id}.md"))).unwrap();
    assert!(md.starts_with("---\n{"), "{md}");
    assert!(md.ends_with("real one is elsewhere\n"));

    let r = e.ok(&["resolve", "--path", "src/auth.rs"]);
    assert_eq!(r[0]["resolution"]["status"], "ok");

    // Lines added above: moved, and the move is saved.
    e.edit("src/auth.rs", |s| format!("// header\n// header\n{s}"));
    let r = e.ok(&["resolve", "--path", "src/auth.rs"]);
    assert_eq!(r[0]["resolution"]["status"], "moved");
    assert_eq!(r[0]["resolution"]["start_line"], 5);
    assert_eq!(e.ok(&["note", "show", &id])["start_line"], 5);
    assert_eq!(e.ok(&["note", "show", &id])["resolution"]["status"], "ok");

    // Code edited: Drifted until confirmed.
    e.edit("src/auth.rs", |s| s.replace("log(ok);", "audit(ok);"));
    let l = e.ok(&["note", "list", "--status", "drifted"]);
    assert_eq!(l.as_array().unwrap().len(), 1);
    e.ok(&["note", "confirm", &id]);
    assert_eq!(e.ok(&["note", "list", "--status", "drifted"]).as_array().unwrap().len(), 0);

    // Code deleted: Orphan, cannot be confirmed, can be re-attached.
    fs::write(e.repo.join("src/auth.rs"), "fn main() {}\n").unwrap();
    let o = e.ok(&["note", "list", "--status", "orphan"]);
    assert_eq!(o[0]["id"], id.as_str());
    assert!(o[0]["resolution"]["start_line"].is_null());
    assert!(e.err(&["note", "confirm", &id]).contains("Orphan"));
    let a = e.ok(&["note", "attach", &id, "--path", "src/auth.rs", "--start", "1"]);
    assert_eq!(a["snapshot"], "fn main() {}");
    assert_eq!(e.ok(&["note", "list", "--status", "orphan"]).as_array().unwrap().len(), 0);

    e.ok(&["note", "delete", &id]);
    assert!(e.err(&["note", "show", &id]).contains("no note"));
}

#[test]
fn unsaved_buffer_text_and_symbols_come_from_stdin() {
    let e = env();
    // The buffer has an extra line the file on disk does not.
    let buffer = format!("// unsaved\n{AUTH}");
    let n = e.ok_in(
        &["note", "add", "--path", "src/auth.rs", "--start", "4", "--end", "8", "--symbol", "login", "--text-stdin", "-m", "x"],
        Some(&buffer),
    );
    assert_eq!(n["kind"], "symbol");
    assert_eq!(n["symbol"], serde_json::json!(["login"]));
    assert!(n["snapshot"].as_str().unwrap().starts_with("fn login"));

    let input = serde_json::json!({
        "text": format!("\n\n{buffer}"),
        "symbols": [{ "symbol": ["login"], "start_line": 6, "end_line": 10 }],
    });
    let r = e.ok_in(&["resolve", "--path", "src/auth.rs", "--stdin"], Some(&input.to_string()));
    assert_eq!(r[0]["resolution"]["status"], "moved");
    assert_eq!(r[0]["resolution"]["start_line"], 6);
}

#[test]
fn file_project_and_outside_notes_and_search() {
    let e = env();
    let f = e.ok(&["note", "add", "--path", "src/auth.rs", "-m", "auth module #question"]);
    assert_eq!(f["kind"], "file");
    let p = e.ok(&["note", "add", "-m", "Auth is done in 3 places"]);
    assert_eq!(p["kind"], "project");
    assert!(p.get("path").is_none());

    let outside = e.data.parent().unwrap().join("lib.go");
    fs::write(&outside, "package lib\n").unwrap();
    let o = e.ok(&["note", "add", "--path", outside.to_str().unwrap(), "--start", "1", "-m", "library"]);
    assert!(Path::new(o["path"].as_str().unwrap()).is_absolute());

    assert!(e.err(&["note", "add", "--path", "missing.rs", "-m", "x"]).contains("no such file"));
    assert!(e.err(&["note", "add", "--path", "src/auth.rs", "--start", "99", "-m", "x"]).contains("outside the file"));

    assert_eq!(e.ok(&["note", "list"]).as_array().unwrap().len(), 3);
    assert_eq!(e.ok(&["note", "list", "--path", "src/auth.rs"]).as_array().unwrap().len(), 1);
    assert_eq!(e.ok(&["note", "list", "--tag", "Question"]).as_array().unwrap().len(), 1);
    let s = e.ok(&["search", "AUTH"]);
    assert_eq!(s.as_array().unwrap().len(), 2);
    assert_eq!(e.ok(&["search", "auth", "--tag", "question"]).as_array().unwrap().len(), 1);

    let id = p["id"].as_str().unwrap();
    let ed = e.ok(&["note", "edit", id, "-m", "Auth is done in 4 places\n"]);
    assert_eq!(ed["body"], "Auth is done in 4 places");
}

#[test]
fn trail_records_jumps_branches_and_survives_drift() {
    let e = env();
    let t = e.ok(&["trail", "new", "how login works"]);
    let tid = t["id"].as_str().unwrap().to_string();
    assert_eq!(t["name"], "how login works");

    let jump = |from: usize, to: usize| {
        e.ok(&[
            "trail", "push", &tid, "--path", "src/auth.rs", "--line", &to.to_string(), "--via", "definition",
            "--from-path", "src/auth.rs", "--from-line", &from.to_string(),
        ])
    };
    let s = jump(1, 3);
    assert_eq!(s["id"], "s2");
    assert_eq!(s["snapshot"], "fn login(user: &str) -> bool {");
    jump(3, 4);
    jump(4, 5);
    assert_eq!(e.ok(&["trail", "back", &tid])["id"], "s3");
    let b = e.ok(&["trail", "push", &tid, "--path", "src/auth.rs", "--line", "6", "--snapshot", "    ok"]);
    assert_eq!(b["parent"], "s3");
    assert_eq!(e.ok(&["trail", "back", &tid])["id"], "s3");
    assert_eq!(e.ok(&["trail", "forward", &tid])["id"], b["id"]);

    e.edit("src/auth.rs", |s| format!("// moved\n{s}"));
    let shown = e.ok(&["trail", "show", &tid, "--resolve"]);
    assert_eq!(shown["stop_count"], 5);
    let s2 = shown["stops"].as_array().unwrap().iter().find(|s| s["id"] == "s2").unwrap().clone();
    assert_eq!(s2["status"], "moved");
    assert_eq!(s2["line"], 4);
    assert_eq!(e.ok(&["trail", "goto", &tid, "s2"])["status"], "ok");

    let list = e.ok(&["trail", "list"]);
    assert_eq!(list[0]["id"], tid.as_str());
    e.ok(&["trail", "rename", &tid, "login flow"]);
    assert_eq!(e.ok(&["trail", "show", &tid])["name"], "login flow");
    assert!(e.err(&["trail", "goto", &tid, "s99"]).contains("no stop"));
    e.ok(&["trail", "delete", &tid]);
    assert_eq!(e.ok(&["trail", "list"]).as_array().unwrap().len(), 0);
}

#[test]
fn in_repo_store() {
    let e = env();
    let p = e.ok(&["--in-repo", "project"]);
    assert!(p["store_dir"].as_str().unwrap().ends_with("repo/.codereader"));
    e.ok(&["--in-repo", "note", "add", "-m", "shared"]);
    assert!(e.repo.join(".codereader/notes").is_dir());
}
