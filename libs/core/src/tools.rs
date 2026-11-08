//! `ccop tools`: which tools and MCP servers each session used, and what
//! they cost. One row per session and tool; the app adds them up by tool,
//! server, project and session for the sessions its list shows.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

use crate::Session;
use crate::anatomy::Anatomy;
use crate::spend::CauseKind;
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
        ToolsReport { sessions: self.sessions.clone(), tools, uses }
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
