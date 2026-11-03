//! Runs the real `ccop` binary on a fake `~/.claude/projects` folder.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::{Value, json};

struct Home {
    _dir: tempfile::TempDir,
    projects: PathBuf,
    cache: PathBuf,
}

impl Home {
    fn new() -> Home {
        let dir = tempfile::tempdir().unwrap();
        let projects = dir.path().join("projects");
        let cache = dir.path().join("cache");
        fs::create_dir_all(&projects).unwrap();
        Home { projects, cache, _dir: dir }
    }

    fn file(&self, rel: &str) -> PathBuf {
        let p = self.projects.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        p
    }

    fn ccop(&self, args: &[&str]) -> (bool, String, String) {
        let out = Command::new(env!("CARGO_BIN_EXE_ccop"))
            .args(args)
            .env("CCOP_PROJECTS_DIR", &self.projects)
            .env("CCOP_CACHE_DIR", &self.cache)
            .output()
            .unwrap();
        (out.status.success(), String::from_utf8(out.stdout).unwrap(), String::from_utf8(out.stderr).unwrap())
    }

    fn sessions(&self) -> Vec<Value> {
        let (ok, out, err) = self.ccop(&["sessions", "--json"]);
        assert!(ok, "{err}");
        serde_json::from_str(&out).unwrap()
    }
}

fn append(path: &Path, text: &str) {
    OpenOptions::new().create(true).append(true).open(path).unwrap().write_all(text.as_bytes()).unwrap();
}

fn user(text: &str, at: &str) -> String {
    json!({"type": "user", "sessionId": "s1", "cwd": "/Users/me/shop", "gitBranch": "main", "timestamp": at,
           "message": {"role": "user", "content": text}})
    .to_string()
        + "\n"
}

fn answer(id: &str, model: &str, read: u64, output: u64, at: &str) -> String {
    json!({"type": "assistant", "requestId": format!("req-{id}"), "timestamp": at,
           "message": {"id": id, "model": model, "usage": {"input_tokens": 2, "cache_creation_input_tokens": 10,
                       "cache_read_input_tokens": read, "output_tokens": output}}})
    .to_string()
        + "\n"
}

fn total(s: &Value) -> u64 {
    let u = &s["usage"];
    ["input_tokens", "cache_write_tokens", "cache_read_tokens", "output_tokens"].iter().map(|k| u[k].as_u64().unwrap()).sum()
}

#[test]
fn a_session_with_its_subagents_and_the_newest_first() {
    let h = Home::new();
    let main = h.file("-Users-me-shop/s1.jsonl");
    append(&main, &user("add a cart", "2026-11-01T10:00:00Z"));
    append(&main, &answer("m1", "claude-opus-5-5", 100, 5, "2026-11-01T10:00:03Z"));
    append(&main, &answer("m1", "claude-opus-5-5", 100, 5, "2026-11-01T10:00:03Z"));
    append(&main, &json!({"type": "ai-title", "aiTitle": "Cart feature", "sessionId": "s1"}).to_string());
    append(&main, "\n");
    append(&h.file("-Users-me-shop/s1/subagents/agent-a1.jsonl"), &answer("x1", "claude-haiku-5-5", 50, 7, "2026-11-01T10:01:00Z"));
    let older = h.file("-Users-me-other/s0.jsonl");
    append(&older, &json!({"type": "user", "cwd": "/Users/me/other", "timestamp": "2026-10-01T09:00:00Z", "message": {"content": "old work"}}).to_string());
    append(&older, "\n");

    let list = h.sessions();
    assert_eq!(list.len(), 2);
    let s = &list[0];
    assert_eq!((s["id"].as_str(), s["title"].as_str(), s["project_dir"].as_str()), (Some("s1"), Some("Cart feature"), Some("/Users/me/shop")));
    assert_eq!((s["subagents"].as_u64(), s["usage"]["requests"].as_u64(), s["prompts"].as_u64()), (Some(1), Some(2), Some(1)));
    assert_eq!(total(s), (2 + 10 + 100 + 5) + (2 + 10 + 50 + 7));
    assert_eq!(s["models"][0]["model"], "claude-opus-5-5");
    assert_eq!(list[1]["title"], "old work");

    let (ok, out, _) = h.ccop(&["sessions", "--json", "--search", "OLD"]);
    assert!(ok);
    assert_eq!(serde_json::from_str::<Vec<Value>>(&out).unwrap().len(), 1);
    let (ok, out, _) = h.ccop(&["projects", "--json"]);
    assert!(ok);
    let projects: Vec<Value> = serde_json::from_str(&out).unwrap();
    assert_eq!(projects[0]["project_dir"], "/Users/me/shop");
}

#[test]
fn a_growing_file_is_read_from_where_it_ended() {
    let h = Home::new();
    let main = h.file("-Users-me-shop/s1.jsonl");
    append(&main, &user("go", "2026-11-01T10:00:00Z"));
    let first = answer("m1", "opus", 100, 5, "2026-11-01T10:00:03Z");
    append(&main, &first);
    assert_eq!(total(&h.sessions()[0]), 117);

    // The rest of the same answer, a new answer, and half of a third line.
    append(&main, &first);
    append(&main, &answer("m2", "opus", 200, 1, "2026-11-01T10:00:09Z"));
    let third = answer("m3", "opus", 1000, 1, "2026-11-01T10:00:20Z");
    let (head, tail) = third.split_at(40);
    append(&main, head);
    let s = &h.sessions()[0];
    assert_eq!((total(s), s["usage"]["requests"].as_u64()), (117 + 213, Some(2)));

    // The line ends: it counts once, now.
    append(&main, tail);
    let s = &h.sessions()[0];
    assert_eq!((total(s), s["usage"]["requests"].as_u64()), (117 + 213 + 1013, Some(3)));
}

#[test]
fn a_rewritten_or_deleted_file_is_read_again_or_dropped() {
    let h = Home::new();
    let main = h.file("-Users-me-shop/s1.jsonl");
    append(&main, &user("go", "2026-11-01T10:00:00Z"));
    append(&main, &answer("m1", "opus", 100, 5, "2026-11-01T10:00:03Z"));
    append(&main, &answer("m2", "opus", 100, 5, "2026-11-01T10:00:04Z"));
    assert_eq!(total(&h.sessions()[0]), 234);

    fs::write(&main, user("again", "2026-11-01T11:00:00Z") + &answer("m9", "opus", 1, 1, "2026-11-01T11:00:01Z")).unwrap();
    let s = &h.sessions()[0];
    assert_eq!((total(s), s["first_prompt"].as_str()), (14, Some("again")));

    fs::remove_file(&main).unwrap();
    assert!(h.sessions().is_empty());
}

#[test]
fn show_finds_a_session_by_the_start_of_its_id() {
    let h = Home::new();
    for id in ["abc111", "abc222"] {
        append(&h.file(&format!("-p/{id}.jsonl")), &user("x", "2026-11-01T10:00:00Z"));
    }
    let (ok, out, _) = h.ccop(&["show", "abc1", "--json"]);
    assert!(ok);
    assert_eq!(serde_json::from_str::<Value>(&out).unwrap()["id"], "abc111");
    let (ok, _, err) = h.ccop(&["show", "abc"]);
    assert!(!ok);
    assert!(err.contains("2 sessions start with"), "{err}");
    let (ok, _, err) = h.ccop(&["show", "zzz"]);
    assert!(!ok);
    assert!(err.contains("no session id starts with"), "{err}");
}

#[test]
fn no_projects_folder_means_no_sessions() {
    let h = Home::new();
    fs::remove_dir(&h.projects).unwrap();
    assert!(h.sessions().is_empty());
}

#[test]
fn usage_gives_hourly_tokens_and_cost_for_main_files_and_subagents() {
    let h = Home::new();
    let now = chrono::Utc::now();
    let at = |mins_ago: i64| (now - chrono::Duration::minutes(mins_ago)).to_rfc3339();
    let main = h.file("-Users-me-shop/s1.jsonl");
    // One answer on two lines, two hours ago: counts once.
    append(&main, &answer("m1", "claude-opus-5-5", 1_000, 10, &at(120)));
    append(&main, &answer("m1", "claude-opus-5-5", 1_000, 10, &at(120)));
    append(&h.file("-Users-me-shop/s1/subagents/agent-a1.jsonl"), &answer("x1", "claude-sonnet-5-5", 1_000, 10, &at(1)));
    // Older than --days: left out.
    append(&main, &answer("m0", "claude-opus-5-5", 1_000, 10, &at(3 * 24 * 60)));
    let (ok, out, err) = h.ccop(&["usage", "--json", "--days", "2"]);
    assert!(ok, "{err}");
    let v: Value = serde_json::from_str(&out).unwrap();
    let hours = v["hours"].as_array().unwrap();
    let calls: u64 = hours.iter().map(|h| h["usage"]["requests"].as_u64().unwrap()).sum();
    let cost: u64 = hours.iter().map(|h| h["cost_micros"].as_u64().unwrap()).sum();
    assert_eq!(calls, 2);
    // answer(): 2 input, 10 cache write (5-minute), 1000 cache read, 10 output.
    // Opus 5.5: 2×4 + 10×5 + 1000×0.20 + 10×20 = 458; Sonnet 5.5: 2×2 + 10×2.5 + 1000×0.20 + 10×10 = 329.
    assert_eq!(cost, 458 + 329);
    assert!(hours.windows(2).all(|w| w[0]["start"].as_str() < w[1]["start"].as_str()));
}
