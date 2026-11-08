//! `api/sessions.example.json` is what `ccop sessions --json` prints. The
//! Swift app's `SessionContractTests` decodes the same file, so the two sides
//! cannot drift apart without a test failing.

use ccop_core::Session;
use serde_json::Value;

#[test]
fn the_example_has_exactly_the_fields_a_session_has() {
    let text = include_str!("../../../api/sessions.example.json");
    let example: Value = serde_json::from_str(text).unwrap();
    let sessions: Vec<Session> = serde_json::from_str(text).unwrap();
    assert_eq!(sessions.len(), 2);
    // Written back, it is the same JSON: no field is missing or extra.
    let again = serde_json::to_value(&sessions).unwrap();
    assert_eq!(again, example);
}

/// `api/anatomy.example.json` is `ccop anatomy --json` for a small session.
/// Run with UPDATE_EXAMPLES=1 to write it again after a change to the types.
#[test]
fn the_anatomy_example_is_what_the_code_makes() {
    use ccop_core::anatomy::{LaneMeta, LaneReader, build};
    use serde_json::json;
    let main_lines = [
        json!({"type": "user", "timestamp": "2026-11-02T10:00:00Z", "message": {"content": "write the report"}}),
        json!({"type": "assistant", "requestId": "r1", "timestamp": "2026-11-02T10:00:04Z", "message": {"id": "m1", "model": "claude-opus-5-5",
            "content": [{"type": "text", "text": "Reading."}, {"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "/p/notes.md"}},
                        {"type": "tool_use", "id": "t2", "name": "Agent", "input": {"description": "Research", "subagent_type": "general-purpose"}}],
            "usage": {"input_tokens": 3, "cache_creation_input_tokens": 20000, "cache_read_input_tokens": 0, "output_tokens": 120}}}),
        json!({"type": "user", "timestamp": "2026-11-02T10:00:05Z", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "x".repeat(4000)}]}}),
        json!({"type": "user", "timestamp": "2026-11-02T10:00:06Z", "toolUseResult": {"agentId": "a1"},
            "message": {"content": [{"type": "tool_result", "tool_use_id": "t2", "content": "launched"}]}}),
        json!({"type": "assistant", "requestId": "r2", "timestamp": "2026-11-02T10:01:00Z", "message": {"id": "m2", "model": "claude-opus-5-5",
            "content": [{"type": "text", "text": "Done."}],
            "usage": {"input_tokens": 1, "cache_creation_input_tokens": 1700, "cache_read_input_tokens": 20003, "output_tokens": 40}}}),
        json!({"type": "system", "subtype": "compact_boundary", "timestamp": "2026-11-02T10:02:00Z",
            "compactMetadata": {"trigger": "auto", "preTokens": 21704, "postTokens": 2000, "durationMs": 5000}}),
        json!({"type": "user", "timestamp": "2026-11-02T10:03:00Z", "message": {"content": "push"}}),
        json!({"type": "assistant", "requestId": "r3", "timestamp": "2026-11-02T10:03:05Z", "message": {"id": "m3", "model": "claude-opus-5-5",
            "content": [{"type": "tool_use", "id": "t3", "name": "Bash", "input": {"command": "git push", "description": "Push"}}],
            "usage": {"input_tokens": 1, "cache_creation_input_tokens": 2500, "cache_read_input_tokens": 20000, "output_tokens": 30}}}),
        json!({"type": "user", "timestamp": "2026-11-02T10:03:09Z", "message": {"content": [{"type": "tool_result", "tool_use_id": "t3", "content": "rejected", "is_error": true}]}}),
        json!({"type": "user", "isMeta": true, "timestamp": "2026-11-02T10:03:20Z", "message": {"content":
            "Another Claude session sent a message:\n<agent-message from=\"a1\">\n[Subagent hand-back] The report follows:\n  The topic needs two sections.\n</agent-message>"}}),
        json!({"type": "assistant", "requestId": "r4", "timestamp": "2026-11-02T10:03:25Z", "message": {"id": "m4", "model": "claude-opus-5-5",
            "content": [{"type": "text", "text": "Noted."}],
            "usage": {"input_tokens": 1, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 22501, "output_tokens": 10}}}),
    ];
    let sub_lines = [
        json!({"type": "user", "isSidechain": true, "timestamp": "2026-11-02T10:00:06Z", "message": {"content": "Research the topic"}}),
        json!({"type": "assistant", "requestId": "s1", "timestamp": "2026-11-02T10:00:20Z", "message": {"id": "sm1", "model": "claude-sonnet-5-5",
            "content": [{"type": "tool_use", "id": "u1", "name": "WebSearch", "input": {"query": "report format"}}],
            "usage": {"input_tokens": 2, "cache_creation_input_tokens": 9000, "cache_read_input_tokens": 0, "output_tokens": 50}}}),
        json!({"type": "user", "timestamp": "2026-11-02T10:00:30Z", "message": {"content": [{"type": "tool_result", "tool_use_id": "u1", "content": "results"}]}}),
        json!({"type": "assistant", "requestId": "s2", "timestamp": "2026-11-02T10:00:50Z", "message": {"id": "sm2", "model": "claude-sonnet-5-5",
            "content": [{"type": "text", "text": "Found it."}],
            "usage": {"input_tokens": 1, "cache_creation_input_tokens": 300, "cache_read_input_tokens": 9002, "output_tokens": 25}}}),
    ];
    let mut main = LaneReader::main();
    for l in &main_lines {
        main.feed(&l.to_string());
    }
    let meta: LaneMeta = serde_json::from_str(r#"{"agentType":"general-purpose","description":"Research","toolUseId":"t2"}"#).unwrap();
    let mut sub = LaneReader::subagent("a1", meta);
    for l in &sub_lines {
        sub.feed(&l.to_string());
    }
    let anatomy = build("s1", main.finish(), vec![sub.finish()]);
    let text = serde_json::to_string_pretty(&anatomy).unwrap() + "\n";
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../api/anatomy.example.json");
    if std::env::var_os("UPDATE_EXAMPLES").is_some() {
        std::fs::write(path, &text).unwrap();
    }
    let saved = std::fs::read_to_string(path).expect("run with UPDATE_EXAMPLES=1 to write api/anatomy.example.json");
    assert_eq!(saved, text, "api/anatomy.example.json is out of date: run with UPDATE_EXAMPLES=1 and update the Swift types");
}

/// `api/tools.example.json` is `ccop tools --json` for two small sessions.
/// Run with UPDATE_EXAMPLES=1 to write it again after a change to the types.
#[test]
fn the_tools_example_is_what_the_code_makes() {
    use ccop_core::anatomy::{LaneReader, build};
    use ccop_core::tools::ToolUses;
    use serde_json::json;
    let sessions: Vec<Session> = serde_json::from_str(include_str!("../../../api/sessions.example.json")).unwrap();
    let anatomy = |id: &str, tools: &[(&str, bool)]| {
        let mut r = LaneReader::main();
        r.feed(&json!({"type": "user", "timestamp": "2026-11-02T10:00:00Z", "message": {"content": "go"}}).to_string());
        for (i, (name, error)) in tools.iter().enumerate() {
            r.feed(
                &json!({"type": "assistant", "requestId": format!("r{i}"), "timestamp": format!("2026-11-02T10:0{i}:01Z"),
                    "message": {"id": format!("m{i}"), "model": "claude-opus-5-5", "content": [{"type": "tool_use", "id": format!("t{i}"), "name": name, "input": {}}],
                                "usage": {"input_tokens": 1, "cache_read_input_tokens": 1000, "output_tokens": 20}}})
                .to_string(),
            );
            r.feed(
                &json!({"type": "user", "timestamp": format!("2026-11-02T10:0{i}:03Z"),
                    "message": {"content": [{"type": "tool_result", "tool_use_id": format!("t{i}"), "content": "ok", "is_error": error}]}})
                .to_string(),
            );
        }
        r.feed(
            &json!({"type": "assistant", "requestId": "rl", "timestamp": "2026-11-02T10:09:00Z",
                "message": {"id": "ml", "model": "claude-opus-5-5", "content": [], "usage": {"input_tokens": 1, "cache_read_input_tokens": 1000, "output_tokens": 5}}})
            .to_string(),
        );
        build(id, r.finish(), Vec::new())
    };
    let mut all = ToolUses::of(&sessions[0], &anatomy(&sessions[0].id, &[("Bash", false), ("mcp__wiki__get_page", false), ("mcp__wiki__search", true)]));
    all.merge(ToolUses::of(&sessions[1], &anatomy(&sessions[1].id, &[("Bash", true), ("mcp__plugin_box_box__open", false)])));
    let text = serde_json::to_string_pretty(&all.report()).unwrap() + "\n";
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../api/tools.example.json");
    if std::env::var_os("UPDATE_EXAMPLES").is_some() {
        std::fs::write(path, &text).unwrap();
    }
    let saved = std::fs::read_to_string(path).expect("run with UPDATE_EXAMPLES=1 to write api/tools.example.json");
    assert_eq!(saved, text, "api/tools.example.json is out of date: run with UPDATE_EXAMPLES=1 and update the Swift types");
}
