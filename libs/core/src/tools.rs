//! `ccop tools`: which tools and MCP servers each session used, and what
//! they cost. One row per session and tool; the app adds them up by tool,
//! server, project and session for the sessions its list shows.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::Session;
use crate::anatomy::Anatomy;
use crate::spend::{CallCost, CauseKind};
use crate::timing::{clock_by_name, tool_name};

/// The server of an MCP tool, as in its name: `mcp__wiki__get_page` → `wiki`.
/// None for a tool that is not from an MCP server.
pub fn server_of(tool: &str) -> Option<&str> {
    let rest = tool.strip_prefix("mcp__")?;
    let (server, name) = rest.split_once("__")?;
    (!server.is_empty() && !name.is_empty()).then_some(server)
}

/// `ccop tools --json`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ToolsReport {
    pub sessions: Vec<ToolSession>,
    pub tools: Vec<ToolInfo>,
    /// One per session and tool that it called.
    pub uses: Vec<ToolUse>,
    /// The costliest calls of each use, at most `CALLS_PER_USE`, so the
    /// costliest calls of any list of sessions are here up to that number.
    pub calls: Vec<ToolCallCost>,
}

/// How many of the costliest calls of each session and tool the JSON keeps.
/// All sessions have about 150,000 calls; 20 each keeps about 46,000.
pub const CALLS_PER_USE: usize = 20;

/// The longest text of a call in the JSON, in characters.
const CALL_TEXT_CHARS: usize = 160;

/// One tool call of a session.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ToolCallCost {
    /// The index in `sessions`.
    pub session: usize,
    /// The index in `tools`.
    pub tool: usize,
    /// `Lane.id`: `main`, or a subagent's id.
    pub lane: String,
    /// A subagent's `Lane.name`; None for the main lane.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lane_name: Option<String>,
    /// The index of the call in `Lane.events`.
    pub event: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    pub start: DateTime<Utc>,
    /// Its part of the model call after it (see `spend::Cause`).
    pub cost_micros: u64,
    /// From the call to its result.
    pub ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_bytes: Option<u64>,
    pub is_error: bool,
    /// A short form of the input (for Bash: its description, or its command).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// Bash: the start of its command.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Bash: the program it ran (`sed`, `node build.js context`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ToolSession {
    pub id: String,
    pub title: String,
    pub project_dir: String,
    /// The whole session's cost, so a tool's part of it can be shown.
    pub cost_micros: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ToolInfo {
    pub name: String,
    /// The MCP server, as in the tool's name; None for Claude Code's own tools.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ToolUse {
    /// The index in `sessions`.
    pub session: usize,
    /// The index in `tools`.
    pub tool: usize,
    /// The model calls that read this tool's results (`Cause.cost_micros`).
    pub cost_micros: u64,
    pub calls: u64,
    pub errors: u64,
    /// Clock time in the session; calls sent together count once.
    pub ms: u64,
}

#[derive(Debug, Clone, Default)]
struct Use {
    session: usize,
    tool: String,
    cost: u64,
    calls: u64,
    errors: u64,
    ms: u64,
    /// The costliest calls, the most cost first; `session` and `tool` are not set.
    top: Vec<ToolCallCost>,
}

/// The tool uses of one session, or of many added up with `merge`.
#[derive(Debug, Clone, Default)]
pub struct ToolUses {
    sessions: Vec<ToolSession>,
    tools: BTreeMap<String, ToolInfo>,
    uses: Vec<Use>,
}

impl ToolUses {
    pub fn of(s: &Session, a: &Anatomy) -> ToolUses {
        let spend = &a.spend;
        let ms = clock_by_name(a, |e| Some(tool_name(e)));
        let mut out = ToolUses {
            sessions: vec![ToolSession { id: s.id.clone(), title: s.title.clone(), project_dir: s.project_dir.clone(), cost_micros: spend.cost_micros }],
            ..ToolUses::default()
        };
        for c in spend.causes.iter().filter(|c| c.kind == CauseKind::Tool && (c.count > 0 || c.cost_micros > 0)) {
            out.tools.entry(c.name.clone()).or_insert_with(|| ToolInfo {
                name: c.name.clone(),
                server: server_of(&c.name).map(str::to_string),
                description: c.description.clone(),
                server_description: c.server_description.clone(),
            });
            out.uses.push(Use {
                session: 0,
                tool: c.name.clone(),
                cost: c.cost_micros,
                calls: c.count,
                errors: c.errors,
                ms: ms.get(c.name.as_str()).copied().unwrap_or(0),
                top: costliest(a, &c.items),
            });
        }
        out
    }

    pub fn merge(&mut self, o: ToolUses) {
        let shift = self.sessions.len();
        self.sessions.extend(o.sessions);
        for (name, info) in o.tools {
            let mine = self.tools.entry(name).or_insert_with(|| info.clone());
            if mine.description.is_none() {
                mine.description = info.description;
            }
            if mine.server_description.is_none() {
                mine.server_description = info.server_description;
            }
        }
        self.uses.extend(o.uses.into_iter().map(|u| Use { session: u.session + shift, ..u }));
    }

    /// The JSON: sessions and tools once, the uses point at them.
    pub fn report(&self) -> ToolsReport {
        let tools: Vec<ToolInfo> = self.tools.values().cloned().collect();
        let index: BTreeMap<&str, usize> = tools.iter().enumerate().map(|(i, t)| (t.name.as_str(), i)).collect();
        let uses = self
            .uses
            .iter()
            .map(|u| ToolUse { session: u.session, tool: index[u.tool.as_str()], cost_micros: u.cost, calls: u.calls, errors: u.errors, ms: u.ms })
            .collect();
        let calls = self
            .uses
            .iter()
            .flat_map(|u| {
                let tool = index[u.tool.as_str()];
                u.top.iter().map(move |c| ToolCallCost { session: u.session, tool, ..c.clone() })
            })
            .collect();
        ToolsReport { sessions: self.sessions.clone(), tools, uses, calls }
    }

    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    /// The cost of all sessions, tools or not.
    pub fn cost_micros(&self) -> u64 {
        self.sessions.iter().map(|s| s.cost_micros).sum()
    }

    /// Rows by MCP server (`servers`), or by tool: all tools, or only the
    /// tools of one server (`server`). The most cost first.
    pub fn summary(&self, servers: bool, server: Option<&str>) -> Vec<ToolRow> {
        let mut rows: BTreeMap<String, RowAcc> = BTreeMap::new();
        for u in &self.uses {
            let s = server_of(&u.tool);
            if let Some(want) = server
                && s != Some(want)
            {
                continue;
            }
            let key = if servers {
                match s {
                    Some(s) => s.to_string(),
                    None => continue,
                }
            } else {
                u.tool.clone()
            };
            let acc = rows.entry(key).or_default();
            acc.cost += u.cost;
            acc.calls += u.calls;
            acc.errors += u.errors;
            acc.ms += u.ms;
            acc.sessions.insert(u.session);
            acc.tools.insert(u.tool.clone());
            *acc.projects.entry(project_name(&self.sessions[u.session].project_dir).to_string()).or_default() += u.cost;
        }
        let mut out: Vec<ToolRow> = rows
            .into_iter()
            .map(|(name, a)| {
                let mut projects: Vec<(String, u64)> = a.projects.into_iter().collect();
                projects.sort_by(|x, y| y.1.cmp(&x.1).then(x.0.cmp(&y.0)));
                ToolRow { name, cost_micros: a.cost, calls: a.calls, errors: a.errors, ms: a.ms, sessions: a.sessions.len() as u64, tools: a.tools.len() as u64, projects }
            })
            .collect();
        out.sort_by(|a, b| b.cost_micros.cmp(&a.cost_micros).then(a.name.cmp(&b.name)));
        out
    }

    /// Sessions that called at least one MCP tool, and those that called tools
    /// of two servers or more.
    pub fn mcp_sessions(&self) -> (u64, u64) {
        let mut by_session: BTreeMap<usize, BTreeSet<&str>> = BTreeMap::new();
        for u in &self.uses {
            if let Some(s) = server_of(&u.tool) {
                by_session.entry(u.session).or_default().insert(s);
            }
        }
        (by_session.len() as u64, by_session.values().filter(|s| s.len() >= 2).count() as u64)
    }

    /// The sessions that called a tool (or a server's tools), the most cost first:
    /// session, its cost for those tools, calls, errors.
    pub fn sessions_of(&self, server: Option<&str>, tool: Option<&str>) -> Vec<(&ToolSession, u64, u64, u64)> {
        let mut by: BTreeMap<usize, (u64, u64, u64)> = BTreeMap::new();
        for u in &self.uses {
            let hit = match (server, tool) {
                (_, Some(t)) => u.tool == t,
                (Some(s), None) => server_of(&u.tool) == Some(s),
                (None, None) => true,
            };
            if hit {
                let e = by.entry(u.session).or_default();
                e.0 += u.cost;
                e.1 += u.calls;
                e.2 += u.errors;
            }
        }
        let mut out: Vec<_> = by.into_iter().map(|(i, (c, n, e))| (&self.sessions[i], c, n, e)).collect();
        out.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.id.cmp(&b.0.id)));
        out
    }
}

/// The costliest `CALLS_PER_USE` of these calls, the most cost first; the
/// earlier call first when two cost the same.
fn costliest(a: &Anatomy, items: &[CallCost]) -> Vec<ToolCallCost> {
    let mut items: Vec<&CallCost> = items.iter().collect();
    items.sort_by_key(|i| std::cmp::Reverse(i.cost_micros));
    items
        .into_iter()
        .filter_map(|item| {
            let lane = a.lanes.iter().find(|l| l.id == item.lane)?;
            let e = lane.events.get(item.event)?;
            Some(ToolCallCost {
                session: 0,
                tool: 0,
                lane: lane.id.clone(),
                lane_name: (lane.id != "main").then(|| lane.name.clone()),
                event: item.event,
                tool_use_id: e.tool_use_id.clone(),
                start: e.start,
                cost_micros: item.cost_micros,
                ms: (e.end - e.start).num_milliseconds().max(0) as u64,
                result_bytes: e.result_bytes,
                is_error: e.is_error,
                text: e.text.as_deref().map(cut),
                command: e.command.as_deref().map(cut),
                group: e.group.clone(),
            })
        })
        .take(CALLS_PER_USE)
        .collect()
}

/// The first `CALL_TEXT_CHARS` characters, on one line.
fn cut(text: &str) -> String {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    match line.char_indices().nth(CALL_TEXT_CHARS) {
        Some((at, _)) => format!("{}…", &line[..at]),
        None => line,
    }
}

fn project_name(dir: &str) -> &str {
    dir.trim_end_matches('/').rsplit('/').next().unwrap_or(dir)
}

#[derive(Default)]
struct RowAcc {
    cost: u64,
    calls: u64,
    errors: u64,
    ms: u64,
    sessions: BTreeSet<usize>,
    tools: BTreeSet<String>,
    projects: BTreeMap<String, u64>,
}

/// A line of `ccop tools`: one tool or one MCP server.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolRow {
    pub name: String,
    pub cost_micros: u64,
    pub calls: u64,
    pub errors: u64,
    pub ms: u64,
    pub sessions: u64,
    /// Tools of a server; 1 for a tool.
    pub tools: u64,
    /// Project folder names and their cost, the most cost first.
    pub projects: Vec<(String, u64)>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::anatomy::{LaneReader, build};
    use serde_json::{Value, json};

    fn at(t: &str) -> String {
        format!("2026-11-02T10:{t}Z")
    }

    fn answer(t: &str, id: &str, blocks: Value) -> Value {
        json!({"type": "assistant", "requestId": format!("r{id}"), "timestamp": at(t),
               "message": {"id": id, "model": "claude-opus-5-5", "content": blocks,
                           "usage": {"input_tokens": 1, "cache_read_input_tokens": 100, "output_tokens": 10}}})
    }

    fn call(id: &str, name: &str) -> Value {
        json!({"type": "tool_use", "id": id, "name": name, "input": {}})
    }

    fn result(t: &str, id: &str, error: bool) -> Value {
        json!({"type": "user", "timestamp": at(t),
               "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "ok", "is_error": error}]}})
    }

    /// A prompt, then each tool in turn; a tool whose name ends in `!` fails.
    fn anatomy(id: &str, tools: &[&str]) -> Anatomy {
        let mut r = LaneReader::main();
        r.feed(&json!({"type": "user", "timestamp": at("00:00"), "message": {"content": "go"}}).to_string());
        for (i, t) in tools.iter().enumerate() {
            let name = t.trim_end_matches('!');
            r.feed(&answer(&format!("{:02}:01", i), &format!("m{i}"), json!([call(&format!("t{i}"), name)])).to_string());
            r.feed(&result(&format!("{:02}:02", i), &format!("t{i}"), t.ends_with('!')).to_string());
        }
        r.feed(&answer("59:00", "last", json!([])).to_string());
        build(id, r.finish(), Vec::new())
    }

    fn session(id: &str, project: &str) -> Session {
        Session {
            id: id.into(),
            project_dir: project.into(),
            title: format!("Title {id}"),
            first_prompt: None,
            last_prompt: None,
            git_branch: None,
            version: None,
            started_at: None,
            updated_at: None,
            modified_at: chrono::Utc::now(),
            active: false,
            prompts: 1,
            subagents: 0,
            usage: Default::default(),
            subagent_usage: Default::default(),
            cost_micros: 0,
            models: Vec::new(),
            transcript: format!("/made/up/{id}.jsonl"),
            size_bytes: 0,
            continued_in: None,
        }
    }

    fn uses(id: &str, project: &str, tools: &[&str]) -> ToolUses {
        ToolUses::of(&session(id, project), &anatomy(id, tools))
    }

    fn two_sessions() -> ToolUses {
        let mut all = uses("s1", "/made/up/shop", &["Bash", "mcp__wiki__get_page", "mcp__wiki__search!", "mcp__books__list"]);
        all.merge(uses("s2", "/made/up/farm", &["Bash", "Bash", "mcp__wiki__get_page"]));
        all
    }

    /// Calls of one tool; the model call after call `i` reads `context[i]`
    /// tokens, so each call has its own cost.
    fn anatomy_with(id: &str, tool: &str, input: Value, context: &[u64]) -> Anatomy {
        let mut r = LaneReader::main();
        r.feed(&json!({"type": "user", "timestamp": at("00:00"), "message": {"content": "go"}}).to_string());
        let mut read = 100;
        for (i, next) in context.iter().enumerate() {
            r.feed(
                &json!({"type": "assistant", "requestId": format!("r{i}"), "timestamp": at(&format!("{:02}:01", i)),
                        "message": {"id": format!("m{i}"), "model": "claude-opus-5-5", "content": [{"type": "tool_use", "id": format!("t{i}"), "name": tool, "input": input}],
                                    "usage": {"input_tokens": 1, "cache_read_input_tokens": read, "output_tokens": 10}}})
                .to_string(),
            );
            r.feed(&result(&format!("{:02}:03", i), &format!("t{i}"), i == 1).to_string());
            read = *next;
        }
        r.feed(
            &json!({"type": "assistant", "requestId": "rl", "timestamp": at("59:00"),
                    "message": {"id": "ml", "model": "claude-opus-5-5", "content": [], "usage": {"input_tokens": 1, "cache_read_input_tokens": read, "output_tokens": 10}}})
            .to_string(),
        );
        build(id, r.finish(), Vec::new())
    }

    #[test]
    fn the_report_keeps_the_costliest_calls_of_each_session_and_tool() {
        // 25 calls; call i makes the next model call read (i * 7 % 25 + 1) * 1000 tokens.
        let context: Vec<u64> = (0..25).map(|i| (i * 7 % 25 + 1) * 1000).collect();
        let mut all = ToolUses::of(&session("s1", "/made/up/shop"), &anatomy_with("s1", "Bash", json!({"command": "ls"}), &context));
        all.merge(ToolUses::of(&session("s2", "/made/up/farm"), &anatomy_with("s2", "mcp__wiki__search", json!({"query": "beds"}), &[5000, 9000])));
        let r = all.report();

        let bash: Vec<&ToolCallCost> = r.calls.iter().filter(|c| r.tools[c.tool].name == "Bash").collect();
        assert_eq!(bash.len(), CALLS_PER_USE, "25 calls, the costliest 20 kept");
        assert!(bash.iter().all(|c| r.sessions[c.session].id == "s1"));
        assert!(bash.windows(2).all(|w| w[0].cost_micros >= w[1].cost_micros), "the most cost first");
        let kept: u64 = bash.iter().map(|c| c.cost_micros).sum();
        let s1_bash = r.uses.iter().find(|u| r.tools[u.tool].name == "Bash").unwrap();
        assert!(kept < s1_bash.cost_micros, "the 5 cheapest calls are not in the list");
        let cheapest_kept = bash.last().unwrap().cost_micros;
        let lane = &anatomy_with("s1", "Bash", json!({"command": "ls"}), &context).spend;
        let dropped = lane.causes.iter().find(|c| c.name == "Bash").unwrap().items.iter().filter(|i| i.cost_micros < cheapest_kept).count();
        assert_eq!(dropped, 5);

        let wiki: Vec<&ToolCallCost> = r.calls.iter().filter(|c| r.tools[c.tool].name == "mcp__wiki__search").collect();
        assert_eq!(wiki.len(), 2);
        assert!(wiki.iter().all(|c| r.sessions[c.session].id == "s2"), "the second session's calls point at it after the merge");
        assert_eq!(wiki[0].event, 4, "the second call (event 4: prompt, answer, tool, answer, tool) costs more: the call after it reads 9000 tokens");
        assert_eq!(wiki[0].text.as_deref(), Some("beds"));
        assert!(wiki.iter().any(|c| c.is_error), "the second call failed");
        assert_eq!((wiki[0].lane.as_str(), wiki[0].lane_name.as_deref()), ("main", None), "the main lane has no name in the JSON");
        assert!(wiki[0].tool_use_id.is_some());
        assert_eq!(wiki[0].ms, 2000);
    }

    #[test]
    fn a_bash_call_has_its_description_command_and_program() {
        let input = json!({"command": "sed -n '1,20p' notes.txt", "description": "Show the notes"});
        let r = ToolUses::of(&session("s1", "/made/up/shop"), &anatomy_with("s1", "Bash", input, &[1000])).report();
        let c = &r.calls[0];
        assert_eq!(c.text.as_deref(), Some("Show the notes"));
        assert_eq!(c.command.as_deref(), Some("sed -n '1,20p' notes.txt"));
        assert_eq!(c.group.as_deref(), Some("sed"));
    }

    #[test]
    fn a_long_text_is_cut_to_one_line() {
        assert_eq!(cut("one\n  two\tthree"), "one two three");
        let long = "é".repeat(CALL_TEXT_CHARS + 5);
        let short = cut(&long);
        assert_eq!(short.chars().count(), CALL_TEXT_CHARS + 1);
        assert!(short.ends_with('…'));
        assert_eq!(cut(&"a".repeat(CALL_TEXT_CHARS)), "a".repeat(CALL_TEXT_CHARS));
    }

    #[test]
    fn the_server_is_the_middle_part_of_an_mcp_tool_name() {
        assert_eq!(server_of("mcp__wiki__get_page"), Some("wiki"));
        assert_eq!(server_of("mcp__plugin_playwright_playwright__browser_click"), Some("plugin_playwright_playwright"));
        assert_eq!(server_of("Bash"), None);
        assert_eq!(server_of("mcp__wiki"), None);
        assert_eq!(server_of("mcp____x"), None);
    }

    #[test]
    fn one_session_has_a_use_per_tool_and_no_prompts_or_other_causes() {
        let r = uses("s1", "/made/up/shop", &["Bash", "Bash!", "mcp__wiki__get_page"]).report();
        assert_eq!(r.sessions.len(), 1);
        let names: Vec<&str> = r.tools.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["Bash", "mcp__wiki__get_page"]);
        assert_eq!(r.tools[1].server.as_deref(), Some("wiki"));
        assert_eq!(r.tools[0].server, None);
        let bash = r.uses.iter().find(|u| u.tool == 0).unwrap();
        assert_eq!((bash.calls, bash.errors), (2, 1));
        assert!(bash.cost_micros > 0);
        assert!(r.uses.iter().map(|u| u.cost_micros).sum::<u64>() <= r.sessions[0].cost_micros, "a prompt's cost is not a tool's");
    }

    #[test]
    fn merged_uses_point_at_the_right_session_and_tool() {
        let r = two_sessions().report();
        assert_eq!(r.sessions.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["s1", "s2"]);
        let s2_bash = r.uses.iter().find(|u| r.sessions[u.session].id == "s2" && r.tools[u.tool].name == "Bash").unwrap();
        assert_eq!(s2_bash.calls, 2);
        assert_eq!(r.uses.len(), 4 + 2);
    }

    #[test]
    fn servers_add_up_their_tools_and_count_each_session_once() {
        let all = two_sessions();
        let servers = all.summary(true, None);
        assert_eq!(servers.iter().map(|s| s.name.as_str()).collect::<Vec<_>>().len(), 2);
        let wiki = servers.iter().find(|s| s.name == "wiki").unwrap();
        assert_eq!((wiki.calls, wiki.errors, wiki.sessions, wiki.tools), (3, 1, 2, 2));
        assert_eq!(wiki.projects.len(), 2);
        let books = servers.iter().find(|s| s.name == "books").unwrap();
        assert_eq!((books.sessions, books.projects[0].0.as_str()), (1, "shop"));
        assert!(servers.windows(2).all(|w| w[0].cost_micros >= w[1].cost_micros));

        let wiki_tools = all.summary(false, Some("wiki"));
        assert_eq!(wiki_tools.iter().map(|t| t.name.as_str()).collect::<std::collections::BTreeSet<_>>().len(), 2);
        let tools = all.summary(false, None);
        let bash = tools.iter().find(|t| t.name == "Bash").unwrap();
        assert_eq!((bash.calls, bash.sessions), (3, 2));
    }

    #[test]
    fn mcp_sessions_count_sessions_with_one_server_and_with_two() {
        assert_eq!(two_sessions().mcp_sessions(), (2, 1));
        assert_eq!(uses("s9", "/made/up/shop", &["Bash"]).mcp_sessions(), (0, 0));
    }

    #[test]
    fn sessions_of_a_server_or_a_tool_have_the_most_cost_first() {
        let all = two_sessions();
        let wiki = all.sessions_of(Some("wiki"), None);
        assert_eq!(wiki.len(), 2);
        let s1 = wiki.iter().find(|w| w.0.id == "s1").unwrap();
        assert_eq!((s1.2, s1.3), (2, 1));
        assert!(wiki[0].1 >= wiki[1].1);
        let books = all.sessions_of(None, Some("mcp__books__list"));
        assert_eq!(books.iter().map(|b| b.0.id.as_str()).collect::<Vec<_>>(), ["s1"]);
    }
}
