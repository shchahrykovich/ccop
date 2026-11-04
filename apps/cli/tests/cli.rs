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

/// The file of a `fork` subagent: one copied answer, a copy of the call that
/// started it with the result and the task, then its own answer.
fn fork_lines(at: &str) -> (String, String) {
    let copied_call = json!({"type": "assistant", "requestId": "req-m1", "timestamp": "2026-11-02T09:59:00Z",
        "message": {"id": "m1", "model": "claude-opus-5-5",
            "content": [{"type": "tool_use", "id": "toolu_1", "name": "Agent", "input": {"description": "Audit"}}],
            "usage": {"input_tokens": 1, "cache_read_input_tokens": 1000, "output_tokens": 50}}})
    .to_string();
    let task = json!({"type": "user", "isSidechain": true, "timestamp": at, "message": {"content": [
        {"type": "tool_result", "tool_use_id": "toolu_1", "content": "Fork started"},
        {"type": "text", "text": "<fork-boilerplate>rules</fork-boilerplate>\n\nAudit part one."}]}})
    .to_string();
    (format!("{}{copied_call}\n", answer("old", "claude-opus-5-5", 1000, 40, "2026-11-02T09:58:00Z")), format!("{task}\n{}", answer("own", "claude-opus-5-5", 300, 6, at)))
}

const FORK_META: &str = r#"{"agentType":"fork","description":"Audit","toolUseId":"toolu_1"}"#;

#[test]
fn a_fork_counts_its_own_work_in_the_totals_the_tree_and_the_chat() {
    let h = Home::new();
    let main_call = json!({"type": "assistant", "requestId": "req-m1", "timestamp": "2026-11-02T09:59:00Z",
        "message": {"id": "m1", "model": "claude-opus-5-5",
            "content": [{"type": "tool_use", "id": "toolu_1", "name": "Agent", "input": {"description": "Audit"}}],
            "usage": {"input_tokens": 1, "cache_read_input_tokens": 1000, "output_tokens": 50}}})
    .to_string();
    append(&h.file("-p/s1.jsonl"), &format!("{}{main_call}\n", user("go", "2026-11-02T09:57:00Z")));
    let (copy, own) = fork_lines("2026-11-02T10:00:00Z");
    fs::write(h.file("-p/s1/subagents/agent-f1.meta.json"), FORK_META).unwrap();
    append(&h.file("-p/s1/subagents/agent-f1.jsonl"), &format!("{copy}{own}"));

    let s = h.sessions();
    assert_eq!(s[0]["subagent_usage"]["requests"], 1);
    assert_eq!(s[0]["subagent_usage"]["output_tokens"], 6);

    let a = json_of(&h, &["anatomy", "s1", "--json"]);
    let fork = a["lanes"].as_array().unwrap().iter().find(|l| l["id"] == "f1").unwrap();
    assert_eq!(fork["parent"], "main");
    assert_eq!(fork["usage"]["requests"], 1);
    assert_eq!(fork["tool_calls"], 0);
    assert_eq!(fork["events"][0]["text"], "Audit part one.");

    // `ccop chat` must find the events at the indices of the anatomy.
    let chat = json_of(&h, &["chat", "s1", "--lane", "f1", "--json"]);
    assert_eq!(chat["texts"][0]["event"], 0);
    assert_eq!(chat["texts"][0]["text"], "Audit part one.");
}

#[test]
fn a_fork_read_before_its_meta_file_exists_is_counted_right_later() {
    let h = Home::new();
    append(&h.file("-p/s1.jsonl"), &user("go", "2026-11-02T09:57:00Z"));
    let (copy, own) = fork_lines("2026-11-02T10:00:00Z");
    let file = h.file("-p/s1/subagents/agent-f1.jsonl");
    append(&file, &copy);
    assert_eq!(h.sessions()[0]["subagent_usage"]["requests"], 2);

    fs::write(h.file("-p/s1/subagents/agent-f1.meta.json"), FORK_META).unwrap();
    append(&file, &own);
    let s = h.sessions();
    assert_eq!(s[0]["subagent_usage"]["requests"], 1);
    assert_eq!(s[0]["subagent_usage"]["output_tokens"], 6);
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

/// A session with two `sed` calls, a failing `ls`, and a subagent.
fn session_with_tools(h: &Home, id: &str, project: &str, at: &str) {
    let time = |t: &str| format!("{at}T{t}Z");
    let call = |id: &str, command: &str| json!({"type": "tool_use", "id": id, "name": "Bash", "input": {"command": command, "description": command}});
    let said = |msg: &str, out: u64, t: &str, blocks: Value| {
        json!({"type": "assistant", "requestId": format!("r{msg}"), "timestamp": time(t),
               "message": {"id": msg, "model": "claude-opus-5-5", "content": blocks,
                           "usage": {"input_tokens": 1, "cache_read_input_tokens": 100, "output_tokens": out}}})
        .to_string()
            + "\n"
    };
    let done = |use_id: &str, text: &str, error: bool, t: &str| {
        json!({"type": "user", "timestamp": time(t),
               "message": {"content": [{"type": "tool_result", "tool_use_id": use_id, "content": text, "is_error": error}]}})
        .to_string()
            + "\n"
    };
    let main = h.file(&format!("-made-up-{project}/{id}.jsonl"));
    append(&main, &json!({"type": "user", "cwd": format!("/made/up/{project}"), "timestamp": time("10:00:00"), "message": {"content": "fix the cart"}}).to_string());
    append(&main, "\n");
    append(&main, &said(&format!("{id}m1"), 10, "10:00:10", json!([call("t1", "sed -n 1,9p a.md")])));
    append(&main, &done("t1", &"line of the file\n".repeat(1000), false, "10:00:12"));
    append(&main, &said(&format!("{id}m2"), 20, "10:00:15", json!([call("t2", "sed -n 9,20p a.md")])));
    append(&main, &done("t2", "short", false, "10:00:16"));
    append(&main, &said(&format!("{id}m3"), 30, "10:00:20", json!([call("t3", "ls /nothing")])));
    append(&main, &done("t3", "ls: /nothing: No such file or directory", true, "10:00:25"));
    append(&main, &said(&format!("{id}m4"), 40, "10:00:30", json!([])));
    let sub = h.file(&format!("-made-up-{project}/{id}/subagents/agent-a1.jsonl"));
    append(&sub, &json!({"type": "user", "isSidechain": true, "timestamp": time("10:00:11"), "message": {"content": "check prices"}}).to_string());
    append(&sub, "\n");
    append(&sub, &said(&format!("{id}s1"), 100, "10:00:40", json!([])));
    append(&h.file(&format!("-made-up-{project}/{id}/subagents/agent-a1.meta.json")), &json!({"agentType": "reviewer", "description": "Check prices"}).to_string());
}

fn json_of(h: &Home, args: &[&str]) -> Value {
    let (ok, out, err) = h.ccop(args);
    assert!(ok, "{args:?}: {err}");
    serde_json::from_str(&out).unwrap_or_else(|e| panic!("{args:?}: {e}: {out}"))
}

fn today() -> String {
    chrono::Utc::now().format("%Y-%m-%d").to_string()
}

#[test]
fn a_brief_of_one_session_says_what_cost_most_and_how_to_go_further() {
    let h = Home::new();
    session_with_tools(&h, "aaaa1111", "shop", &today());
    let (ok, out, err) = h.ccop(&["brief", "aaaa"]);
    assert!(ok, "{err}");
    assert!(out.contains("aaaa1111") && out.contains("shop"), "{out}");
    assert!(out.contains("WHAT MADE THE MODEL RUN") && out.contains("sed") && out.contains("Check prices"), "{out}");
    assert!(out.contains("ccop cause aaaa1111 NAME"), "{out}");
    assert!(out.len() < 2048, "{} bytes", out.len());

    let b = json_of(&h, &["brief", "aaaa", "--json"]);
    assert_eq!(b["session_id"], "aaaa1111");
    assert_eq!((b["sessions"].as_u64(), b["tool_calls"].as_u64(), b["errors"].as_u64(), b["subagents"].as_u64()), (Some(1), Some(3), Some(1), Some(1)));
}

#[test]
fn a_brief_and_a_top_of_a_period_add_up_the_sessions_of_that_period() {
    let h = Home::new();
    session_with_tools(&h, "aaaa1111", "shop", &today());
    session_with_tools(&h, "bbbb2222", "farm", &today());
    session_with_tools(&h, "cccc3333", "shop", "2020-01-01");

    // With no period: the last 7 days.
    let b = json_of(&h, &["brief", "--json"]);
    assert_eq!(b["sessions"], 2);
    assert_eq!(b["session_id"], Value::Null);
    let (ok, out, _) = h.ccop(&["brief"]);
    assert!(ok);
    assert!(out.contains("aaaa1111") && out.contains("bbbb2222"), "the next command needs the ids: {out}");

    let only_shop = json_of(&h, &["brief", "--project", "shop", "--json"]);
    assert_eq!(only_shop["sessions"], 1);
    let all_time = json_of(&h, &["brief", "--since", "5000w", "--json"]);
    assert_eq!(all_time["sessions"], 3);

    let top = json_of(&h, &["top", "commands", "--json", "--limit", "1"]);
    assert_eq!((top["sessions"].as_u64(), top["total_rows"].as_u64()), (Some(2), Some(2)));
    let rows = top["rows"].as_array().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["name"], "sed");
    assert_eq!((rows[0]["count"].as_u64(), rows[0]["sessions"].as_u64()), (Some(4), Some(2)));

    let by_time = json_of(&h, &["top", "commands", "--by", "time", "--session", "aaaa", "--json"]);
    assert_eq!(by_time["rows"][0]["name"], "ls", "ls took 5 s, the sed calls 3 s");

    for what in ["commands", "causes", "agents", "sessions", "turns", "errors", "projects", "tips"] {
        let (ok, out, err) = h.ccop(&["top", what]);
        assert!(ok, "{what}: {err}");
        assert!(out.contains("2 sessions"), "{what}: {out}");
    }
    let (ok, _, err) = h.ccop(&["top", "nothing"]);
    assert!(!ok);
    assert!(err.contains("commands, causes"), "{err}");
}

#[test]
fn one_session_and_a_filter_together_are_refused() {
    let h = Home::new();
    session_with_tools(&h, "aaaa1111", "shop", &today());
    let (ok, _, err) = h.ccop(&["brief", "aaaa", "--since", "7d"]);
    assert!(!ok);
    assert!(err.contains("not both"), "{err}");
    let (ok, _, err) = h.ccop(&["top", "commands", "--session", "aaaa", "--project", "shop"]);
    assert!(!ok);
    assert!(err.contains("not both"), "{err}");
}

#[test]
fn a_cause_lists_the_calls_that_a_call_can_then_show_cut() {
    let h = Home::new();
    session_with_tools(&h, "aaaa1111", "shop", &today());
    let c = json_of(&h, &["cause", "aaaa", "sed", "--json", "--limit", "1"]);
    assert_eq!((c["name"].as_str(), c["total_calls"].as_u64(), c["calls"].as_array().unwrap().len()), (Some("sed"), Some(2), 1));
    let (ok, text, _) = h.ccop(&["cause", "aaaa", "bash"]);
    assert!(ok);
    assert!(text.contains("t3") && text.contains("ERROR"), "{text}");
    assert!(text.contains("ccop call aaaa1111 TOOL_USE_ID --max-bytes"), "{text}");
    let (ok, _, err) = h.ccop(&["cause", "aaaa", "Grep"]);
    assert!(!ok);
    assert!(err.contains("Bash") && err.contains("sed"), "{err}");

    let whole = json_of(&h, &["call", "aaaa", "t1", "--json"]);
    assert_eq!(whole["output_truncated"], false);
    assert_eq!(whole["output"].as_str().unwrap().len(), 17_000);
    let cut = json_of(&h, &["call", "aaaa", "t1", "--json", "--max-bytes", "100"]);
    assert_eq!(cut["output"].as_str().unwrap().len(), 100);
    assert_eq!((cut["output_truncated"].as_bool(), cut["output_bytes"].as_u64()), (Some(true), Some(17_000)));
    let (ok, text, _) = h.ccop(&["call", "aaaa", "t1", "--max-bytes", "100"]);
    assert!(ok);
    assert!(text.contains("(cut: this is the start of the output)") && text.contains("17000 bytes"), "{text}");
}

#[test]
fn time_splits_the_clock_into_parts_that_add_up() {
    let h = Home::new();
    session_with_tools(&h, "aaaa1111", "shop", &today());
    let t = json_of(&h, &["time", "aaaa", "--json"]);
    let n = |k: &str| t[k].as_u64().unwrap();
    assert_eq!(n("wall_ms"), 40_000);
    assert_eq!(n("model_ms") + n("tools_ms") + n("subagents_ms") + n("waiting_ms"), 40_000);
    assert_eq!(n("tools_ms"), 8_000);
    assert_eq!(t["slowest"][0]["lane"], "a1", "the subagent's call took 29 s");
    let (ok, text, _) = h.ccop(&["time", "aaaa"]);
    assert!(ok);
    assert!(text.contains("CLOCK") && text.contains("SLOWEST CALLS"), "{text}");
}

#[test]
fn the_guide_needs_no_transcripts_and_names_only_real_commands() {
    let out = Command::new(env!("CARGO_BIN_EXE_ccop"))
        .arg("guide")
        .env("CCOP_PROJECTS_DIR", "/made/up/nowhere")
        .env("CCOP_CACHE_DIR", "/made/up/nowhere")
        .output()
        .unwrap();
    assert!(out.status.success());
    let guide = String::from_utf8(out.stdout).unwrap();
    assert!(guide.len() <= ccop_core::help::GUIDE_MAX_BYTES);
    let h = Home::new();
    let mut seen = 0;
    for part in guide.split('`').skip(1).step_by(2) {
        let Some(rest) = part.strip_prefix("ccop ") else { continue };
        let sub = rest.split_whitespace().next().unwrap();
        let (ok, _, err) = h.ccop(&[sub, "--help"]);
        assert!(ok, "the guide names `{sub}`: {err}");
        seen += 1;
    }
    assert!(seen >= 6, "only {seen} commands found in the guide");
}

#[test]
fn the_top_level_help_points_an_agent_at_the_guide() {
    let h = Home::new();
    let (ok, out, _) = h.ccop(&["--help"]);
    assert!(ok);
    assert!(out.contains("ccop guide"), "{out}");
    assert!(!out.contains("help-page"), "a hidden command: {out}");
}

#[test]
fn the_help_page_is_html_with_the_guide_to_copy() {
    let h = Home::new();
    let (ok, out, err) = h.ccop(&["help-page"]);
    assert!(ok, "{err}");
    assert!(out.starts_with("<!doctype html>") && out.contains("Copy for Agent"), "{}", &out[..80]);
}
