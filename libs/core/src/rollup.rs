//! Short answers for agents: `ccop brief`, `ccop top` and `ccop cause`. One
//! session or many are added up into a `Rollup`, and each `Row` is what one
//! line of output says.
//!
//! A session counts as a whole when it was active in the period: its cost is
//! not cut at the start of the period. So a total here can be more than
//! `ccop usage` gives for the same days.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::Session;
use crate::anatomy::Anatomy;
use crate::spend::{CallCost, Cause, CauseKind, ERROR_KEY_CHARS, TipKind};
use crate::timing::{clock_by_name, tool_name};

/// The longest name kept in a row: a prompt or an error can be long.
pub const NAME_CHARS: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum What {
    Commands,
    Causes,
    Agents,
    Sessions,
    Turns,
    Errors,
    Projects,
    Tips,
}

impl What {
    pub fn parse(text: &str) -> Result<What, String> {
        Ok(match text {
            "commands" => What::Commands,
            "causes" => What::Causes,
            "agents" => What::Agents,
            "sessions" => What::Sessions,
            "turns" => What::Turns,
            "errors" => What::Errors,
            "projects" => What::Projects,
            "tips" => What::Tips,
            _ => return Err(format!("{text:?} is not one of commands, causes, agents, sessions, turns, errors, projects, tips")),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum By {
    Cost,
    Time,
}

impl By {
    pub fn parse(text: &str) -> Result<By, String> {
        match text {
            "cost" => Ok(By::Cost),
            "time" => Ok(By::Time),
            _ => Err(format!("{text:?} is not cost or time")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Row {
    pub name: String,
    /// For a next command: a session id, a lane id or a turn number.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// The session of a turn or a tip, when many sessions were added up.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    pub cost_micros: u64,
    /// `cost_micros` as a percent of the whole cost.
    pub percent: f64,
    /// Calls, subagents, prompts or sessions: the text output names which.
    pub count: u64,
    pub errors: u64,
    /// How many sessions have this row.
    pub sessions: u64,
    /// Clock time. For tools and programs: calls sent together count once.
    pub total_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avg_context: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub saving_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Default)]
struct Acc {
    name: String,
    id: Option<String>,
    session: Option<String>,
    cost: u64,
    count: u64,
    errors: u64,
    sessions: u64,
    ms: u64,
    context: f64,
    calls: f64,
    saving: Option<u64>,
    detail: Option<String>,
}

impl Acc {
    fn named(name: &str) -> Acc {
        Acc { name: name.chars().take(NAME_CHARS).collect(), sessions: 1, ..Acc::default() }
    }

    fn add_context(&mut self, avg: u64, calls: f64) {
        self.context += avg as f64 * calls;
        self.calls += calls;
    }

    fn merge(&mut self, o: Acc) {
        self.cost += o.cost;
        self.count += o.count;
        self.errors += o.errors;
        self.sessions += o.sessions;
        self.ms += o.ms;
        self.context += o.context;
        self.calls += o.calls;
        self.saving = match (self.saving, o.saving) {
            (Some(a), Some(b)) => Some(a + b),
            (a, b) => a.or(b),
        };
        self.detail = self.detail.take().or(o.detail);
    }

    fn row(&self, total: u64) -> Row {
        Row {
            name: self.name.clone(),
            id: self.id.clone(),
            session: self.session.clone(),
            cost_micros: self.cost,
            percent: if total > 0 { self.cost as f64 * 100.0 / total as f64 } else { 0.0 },
            count: self.count,
            errors: self.errors,
            sessions: self.sessions,
            total_ms: self.ms,
            avg_context: (self.calls > 0.0).then(|| (self.context / self.calls).round() as u64),
            saving_micros: self.saving,
            detail: self.detail.clone(),
        }
    }
}

fn merge_map<K: Ord>(into: &mut BTreeMap<K, Acc>, from: BTreeMap<K, Acc>) {
    for (k, v) in from {
        match into.get_mut(&k) {
            Some(a) => a.merge(v),
            None => {
                into.insert(k, v);
            }
        }
    }
}

/// One session, or many added up with `merge`.
#[derive(Debug, Clone, Default)]
pub struct Rollup {
    pub sessions: u64,
    pub cost_micros: u64,
    pub tokens: u64,
    pub model_calls: u64,
    pub tool_calls: u64,
    pub errors: u64,
    pub subagents: u64,
    pub wall_ms: u64,
    /// The session's id, title and folder, while there is only one.
    only: Option<(String, String, String)>,
    causes: BTreeMap<(CauseKind, String), Acc>,
    commands: BTreeMap<String, Acc>,
    agent_kinds: BTreeMap<String, Acc>,
    agent_lanes: Vec<Acc>,
    session_rows: Vec<Acc>,
    turns: Vec<Acc>,
    error_kinds: BTreeMap<(String, String), Acc>,
    projects: BTreeMap<String, Acc>,
    tip_kinds: BTreeMap<TipKind, Acc>,
    tips: Vec<Acc>,
}

fn tip_kind_name(kind: TipKind) -> &'static str {
    match kind {
        TipKind::ManyCalls => "Many tool calls: after each result the model reads the whole context again",
        TipKind::Errors => "Failed tool calls: each one usually means one more model call",
        TipKind::Model => "Subagents on a larger model than the work may need",
        TipKind::BigContext => "Agents that read a large context on every call",
        TipKind::BigResults => "Large tool results that stay in the context",
        TipKind::CacheRewrites => "Cache rewrites: a large context written to the cache again",
        TipKind::LateCompaction => "Late compaction: an earlier auto-compact window would cost less",
    }
}

impl Rollup {
    pub fn of(s: &Session, a: &Anatomy) -> Rollup {
        let spend = &a.spend;
        let wall_ms = match (a.started_at, a.ended_at) {
            (Some(start), Some(end)) => (end - start).num_milliseconds().max(0) as u64,
            _ => 0,
        };
        let mut r = Rollup {
            sessions: 1,
            cost_micros: spend.cost_micros,
            tokens: spend.tokens,
            model_calls: spend.lanes.iter().map(|l| l.model_calls).sum(),
            tool_calls: a.lanes.iter().map(|l| l.tool_calls).sum(),
            errors: a.lanes.iter().map(|l| l.errors).sum(),
            subagents: a.lanes.len().saturating_sub(1) as u64,
            wall_ms,
            only: Some((s.id.clone(), s.title.clone(), s.project_dir.clone())),
            ..Rollup::default()
        };
        let tool_ms = clock_by_name(a, |e| Some(tool_name(e)));
        for c in &spend.causes {
            let mut acc = Acc::named(&c.name);
            acc.cost = c.cost_micros;
            acc.count = c.count;
            acc.errors = c.errors;
            acc.add_context(c.avg_context, c.model_calls);
            if c.kind == CauseKind::Tool {
                acc.ms = tool_ms.get(c.name.as_str()).copied().unwrap_or(0);
            }
            r.causes.insert((c.kind, c.name.clone()), acc);
        }
        let group_ms = clock_by_name(a, |e| e.group.as_deref());
        for g in &spend.commands {
            let mut acc = Acc::named(&g.group);
            acc.cost = g.cost_micros;
            acc.count = g.calls;
            acc.errors = g.errors;
            acc.ms = group_ms.get(g.group.as_str()).copied().unwrap_or(0);
            acc.detail = g.example.clone();
            r.commands.insert(g.group.clone(), acc);
        }
        for (lane, ls) in a.lanes.iter().zip(&spend.lanes).skip(1) {
            let model = lane.model.as_deref().unwrap_or("unknown model");
            let kind = format!("{} on {model}", lane.agent_type.as_deref().unwrap_or("no type"));
            let ms = match (lane.started_at, lane.ended_at) {
                (Some(start), Some(end)) => (end - start).num_milliseconds().max(0) as u64,
                _ => 0,
            };
            let mut one = Acc::named(&lane.name);
            one.id = Some(lane.id.clone());
            one.cost = ls.cost_micros;
            one.count = lane.tool_calls;
            one.errors = lane.errors;
            one.ms = ms;
            one.add_context(ls.avg_context, ls.model_calls as f64);
            one.detail = Some(kind.clone());
            r.agent_lanes.push(one);
            let mut acc = Acc::named(&kind);
            acc.cost = ls.cost_micros;
            acc.count = 1;
            acc.errors = lane.errors;
            acc.ms = ms;
            acc.add_context(ls.avg_context, ls.model_calls as f64);
            match r.agent_kinds.get_mut(&kind) {
                Some(a) => {
                    acc.sessions = 0;
                    a.merge(acc);
                }
                None => {
                    r.agent_kinds.insert(kind, acc);
                }
            }
        }
        let mut row = Acc::named(&s.title);
        row.id = Some(s.id.clone());
        row.cost = spend.cost_micros;
        row.count = s.prompts;
        row.errors = r.errors;
        row.ms = wall_ms;
        if let Some(main) = spend.lanes.first() {
            row.add_context(main.avg_context, main.model_calls as f64);
        }
        row.detail = Some(s.project_name().to_string());
        r.session_rows.push(row);
        for t in &a.turns {
            let mut acc = Acc::named(&t.prompt);
            acc.id = Some(t.index.to_string());
            acc.session = Some(s.id.clone());
            acc.cost = t.cost_micros + t.subagent_cost_micros;
            acc.count = t.tool_calls;
            acc.ms = (t.end - t.start).num_milliseconds().max(0) as u64;
            r.turns.push(acc);
        }
        for e in &spend.errors {
            let mut acc = Acc::named(&format!("{}: {}", e.tool, e.message));
            acc.cost = e.cost_micros;
            acc.count = e.count;
            acc.errors = e.count;
            acc.detail = e.cause.clone();
            let key: String = e.message.chars().take(ERROR_KEY_CHARS).collect();
            match r.error_kinds.get_mut(&(e.tool.clone(), key.clone())) {
                Some(a) => {
                    acc.sessions = 0;
                    a.merge(acc);
                }
                None => {
                    r.error_kinds.insert((e.tool.clone(), key), acc);
                }
            }
        }
        let mut project = Acc::named(&s.project_dir);
        project.cost = spend.cost_micros;
        project.count = 1;
        project.errors = r.errors;
        project.ms = wall_ms;
        r.projects.insert(s.project_dir.clone(), project);
        for t in &spend.tips {
            let mut kind = Acc::named(tip_kind_name(t.kind));
            kind.cost = t.cost_micros;
            kind.saving = t.saving_micros;
            kind.count = 1;
            match r.tip_kinds.get_mut(&t.kind) {
                Some(a) => {
                    kind.sessions = 0;
                    a.merge(kind);
                }
                None => {
                    r.tip_kinds.insert(t.kind, kind);
                }
            }
            let mut one = Acc::named(&t.title);
            one.session = Some(s.id.clone());
            one.cost = t.cost_micros;
            one.saving = t.saving_micros;
            one.detail = Some(t.detail.clone());
            r.tips.push(one);
        }
        r
    }

    pub fn merge(&mut self, o: Rollup) {
        self.only = if self.sessions == 0 { o.only } else { None };
        self.sessions += o.sessions;
        self.cost_micros += o.cost_micros;
        self.tokens += o.tokens;
        self.model_calls += o.model_calls;
        self.tool_calls += o.tool_calls;
        self.errors += o.errors;
        self.subagents += o.subagents;
        self.wall_ms += o.wall_ms;
        merge_map(&mut self.causes, o.causes);
        merge_map(&mut self.commands, o.commands);
        merge_map(&mut self.agent_kinds, o.agent_kinds);
        merge_map(&mut self.error_kinds, o.error_kinds);
        merge_map(&mut self.projects, o.projects);
        merge_map(&mut self.tip_kinds, o.tip_kinds);
        self.agent_lanes.extend(o.agent_lanes);
        self.session_rows.extend(o.session_rows);
        self.turns.extend(o.turns);
        self.tips.extend(o.tips);
    }

    /// All rows of one kind, the most cost (or time) first.
    ///
    /// With one session, agents and tips are its own subagents and tips.
    /// With many, they are added up by agent type and model, and by tip kind.
    pub fn rows(&self, what: What, by: By) -> Vec<Row> {
        let one = self.sessions == 1;
        let accs: Vec<&Acc> = match what {
            What::Commands => self.commands.values().collect(),
            What::Causes => self.causes.values().collect(),
            What::Agents if one => self.agent_lanes.iter().collect(),
            What::Agents => self.agent_kinds.values().collect(),
            What::Sessions => self.session_rows.iter().collect(),
            What::Turns => self.turns.iter().collect(),
            What::Errors => self.error_kinds.values().collect(),
            What::Projects => self.projects.values().collect(),
            What::Tips if one => self.tips.iter().collect(),
            What::Tips => self.tip_kinds.values().collect(),
        };
        let mut rows: Vec<Row> = accs.into_iter().filter(|a| a.cost > 0 || a.count > 0).map(|a| a.row(self.cost_micros)).collect();
        match by {
            By::Cost => rows.sort_by(|a, b| b.cost_micros.cmp(&a.cost_micros).then(a.name.cmp(&b.name))),
            By::Time => rows.sort_by(|a, b| b.total_ms.cmp(&a.total_ms).then(b.cost_micros.cmp(&a.cost_micros)).then(a.name.cmp(&b.name))),
        }
        if what == What::Tips {
            rows.sort_by_key(|r| std::cmp::Reverse(r.saving_micros.unwrap_or(r.cost_micros)));
        }
        rows
    }

    fn top(&self, what: What, n: usize) -> Vec<Row> {
        let mut rows = self.rows(what, By::Cost);
        rows.truncate(n);
        rows
    }

    pub fn brief(&self) -> Brief {
        let many = self.sessions > 1;
        let only = self.only.as_ref();
        Brief {
            session_id: only.map(|o| o.0.clone()),
            title: only.map(|o| o.1.clone()),
            project_dir: only.map(|o| o.2.clone()),
            sessions: self.sessions,
            cost_micros: self.cost_micros,
            tokens: self.tokens,
            model_calls: self.model_calls,
            tool_calls: self.tool_calls,
            errors: self.errors,
            subagents: self.subagents,
            wall_ms: self.wall_ms,
            causes: self.top(What::Causes, 5),
            commands: self.top(What::Commands, 5),
            agents: self.top(What::Agents, 3),
            turns: self.top(What::Turns, 3),
            top_sessions: if many { self.top(What::Sessions, 3) } else { Vec::new() },
            projects: if many { self.top(What::Projects, 3) } else { Vec::new() },
            tips: self.top(What::Tips, 3).into_iter().map(|t| Row { detail: None, ..t }).collect(),
        }
    }
}

/// `ccop brief`: the first look at one session or many.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Brief {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    pub sessions: u64,
    pub cost_micros: u64,
    pub tokens: u64,
    pub model_calls: u64,
    pub tool_calls: u64,
    pub errors: u64,
    pub subagents: u64,
    pub wall_ms: u64,
    pub causes: Vec<Row>,
    pub commands: Vec<Row>,
    pub agents: Vec<Row>,
    pub turns: Vec<Row>,
    pub top_sessions: Vec<Row>,
    pub projects: Vec<Row>,
    pub tips: Vec<Row>,
}

/// `ccop cause`: one cause or one Bash program, and the calls behind it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CauseReport {
    pub name: String,
    /// All calls of the cause; `calls` has at most the limit.
    pub total_calls: usize,
    pub errors: u64,
    pub cost_micros: u64,
    pub percent: f64,
    pub calls: Vec<CauseCall>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CauseCall {
    pub lane: String,
    pub lane_name: String,
    /// The index in the lane's events, as in `ccop chat`.
    pub event: usize,
    /// For `ccop call`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    pub cost_micros: u64,
    pub ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_bytes: Option<u64>,
    pub is_error: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

fn find_cause<'a>(causes: &'a [Cause], name: &str) -> Option<&'a Cause> {
    let want = match name.to_lowercase().as_str() {
        "prompts" => "your prompts".to_string(),
        "tasks" => "tasks from the lead".to_string(),
        "reports" => "subagent reports".to_string(),
        other => other.to_string(),
    };
    causes.iter().find(|c| c.name.to_lowercase() == want)
}

/// The calls behind a cause (a tool's name, `prompts`, `tasks`, `reports`,
/// `compaction`, `other`) or behind a Bash program (`sed`). The error lists what there is.
pub fn cause_report(a: &Anatomy, name: &str, by: By, limit: usize) -> Result<CauseReport, Vec<String>> {
    let spend = &a.spend;
    let lower = name.to_lowercase();
    let (title, errors, cost, items): (&str, u64, u64, &[CallCost]) = if let Some(c) = find_cause(&spend.causes, name) {
        (&c.name, c.errors, c.cost_micros, &c.items)
    } else if let Some(g) = spend.commands.iter().find(|g| g.group.to_lowercase() == lower) {
        (&g.group, g.errors, g.cost_micros, &g.items)
    } else {
        return Err(spend.causes.iter().map(|c| c.name.clone()).chain(spend.commands.iter().map(|g| g.group.clone())).collect());
    };
    let mut calls: Vec<CauseCall> = items
        .iter()
        .filter_map(|item| {
            let lane = a.lanes.iter().find(|l| l.id == item.lane)?;
            let e = lane.events.get(item.event)?;
            Some(CauseCall {
                lane: lane.id.clone(),
                lane_name: lane.name.clone(),
                event: item.event,
                tool_use_id: e.tool_use_id.clone(),
                cost_micros: item.cost_micros,
                ms: (e.end - e.start).num_milliseconds().max(0) as u64,
                result_bytes: e.result_bytes,
                is_error: e.is_error,
                text: e.text.clone(),
            })
        })
        .collect();
    match by {
        By::Cost => calls.sort_by_key(|c| std::cmp::Reverse(c.cost_micros)),
        By::Time => calls.sort_by_key(|c| std::cmp::Reverse(c.ms)),
    }
    let total_calls = calls.len();
    calls.truncate(limit);
    Ok(CauseReport {
        name: title.to_string(),
        total_calls,
        errors,
        cost_micros: cost,
        percent: if spend.cost_micros > 0 { cost as f64 * 100.0 / spend.cost_micros as f64 } else { 0.0 },
        calls,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::anatomy::{Lane, LaneMeta, LaneReader, build};
    use serde_json::{Value, json};

    fn lane(reader: LaneReader, lines: &[Value]) -> Lane {
        let mut r = reader;
        for l in lines {
            r.feed(&l.to_string());
        }
        r.finish()
    }

    fn at(t: &str) -> String {
        format!("2026-11-02T10:{t}Z")
    }

    fn prompt(t: &str, text: &str) -> Value {
        json!({"type": "user", "timestamp": at(t), "message": {"content": text}})
    }

    /// 1 input and 100 cache read on Opus 5.5: 4 + 20 = 24 µ$, plus `out` × 20.
    fn answer(t: &str, id: &str, out: u64, blocks: Value) -> Value {
        json!({"type": "assistant", "requestId": format!("r{id}"), "timestamp": at(t),
               "message": {"id": id, "model": "claude-opus-5-5", "content": blocks,
                           "usage": {"input_tokens": 1, "cache_read_input_tokens": 100, "output_tokens": out}}})
    }

    fn bash(id: &str, command: &str) -> Value {
        json!({"type": "tool_use", "id": id, "name": "Bash", "input": {"command": command, "description": command}})
    }

    fn result(t: &str, id: &str, error: bool) -> Value {
        json!({"type": "user", "timestamp": at(t),
               "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "no such file here", "is_error": error}]}})
    }

    /// A session with a prompt, two `sed` calls, one `ls` that fails and a subagent.
    fn anatomy(id: &str) -> Anatomy {
        let main = lane(
            LaneReader::main(),
            &[
                prompt("00:00", "fix the cart"),
                answer("00:01", "m1", 10, json!([bash("t1", "sed -n 1,9p a.md")])),
                result("00:03", "t1", false),
                answer("00:04", "m2", 20, json!([bash("t2", "sed -n 9,20p a.md")])),
                result("00:05", "t2", false),
                answer("00:06", "m3", 30, json!([bash("t3", "ls /nothing")])),
                result("00:16", "t3", true),
                answer("00:17", "m4", 40, json!([])),
            ],
        );
        let sub = lane(
            LaneReader::subagent("a1", LaneMeta { description: Some("Check prices".into()), agent_type: Some("reviewer".into()), ..LaneMeta::default() }),
            &[
                json!({"type": "user", "isSidechain": true, "timestamp": at("00:02"), "message": {"content": "Check"}}),
                answer("00:30", "s1", 100, json!([])),
            ],
        );
        build(id, main, vec![sub])
    }

    fn session(id: &str, project: &str, title: &str) -> Session {
        Session {
            id: id.into(),
            project_dir: project.into(),
            title: title.into(),
            first_prompt: None,
            last_prompt: None,
            git_branch: None,
            version: None,
            started_at: None,
            updated_at: None,
            modified_at: chrono::Utc::now(),
            active: false,
            prompts: 1,
            subagents: 1,
            usage: Default::default(),
            subagent_usage: Default::default(),
            cost_micros: 0,
            models: Vec::new(),
            transcript: format!("/made/up/{id}.jsonl"),
            size_bytes: 0,
            continued_in: None,
        }
    }

    fn one(id: &str) -> Rollup {
        Rollup::of(&session(id, "/made/up/shop", "Cart fix"), &anatomy(id))
    }

    fn many() -> Rollup {
        let mut all = Rollup::default();
        all.merge(one("s1"));
        all.merge(Rollup::of(&session("s2", "/made/up/farm", "Farm fix"), &anatomy("s2")));
        all
    }

    #[test]
    fn rows_of_one_session_have_the_most_cost_first_and_a_percent() {
        let r = one("s1");
        assert_eq!((r.sessions, r.subagents, r.tool_calls, r.errors), (1, 1, 3, 1));
        let commands = r.rows(What::Commands, By::Cost);
        let names: Vec<&str> = commands.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["sed", "ls"], "sed paid for the answers of 20 and 30 tokens, ls for 40");
        // A call pays for the model call after it: 24 + 20×20 and 24 + 30×20.
        let sed = &commands[0];
        assert_eq!((sed.count, sed.errors, sed.sessions), (2, 0, 1));
        assert_eq!(sed.cost_micros, (24 + 400) + (24 + 600));
        assert_eq!(sed.total_ms, 3_000);
        assert!((sed.percent - sed.cost_micros as f64 * 100.0 / r.cost_micros as f64).abs() < 1e-9);
        assert_eq!(sed.detail.as_deref(), Some("sed -n 1,9p a.md"));
        let causes = r.rows(What::Causes, By::Cost);
        assert_eq!(causes[0].name, "Tasks from the lead");
        assert_eq!(causes.iter().map(|c| c.cost_micros).sum::<u64>(), r.cost_micros);
        assert_eq!(causes.iter().find(|c| c.name == "Bash").unwrap().total_ms, 13_000);
    }

    #[test]
    fn rows_can_be_sorted_by_time() {
        let names: Vec<String> = one("s1").rows(What::Commands, By::Time).into_iter().map(|c| c.name).collect();
        assert_eq!(names, ["ls", "sed"], "ls took 10 s, sed 3 s");
        let by_cost = one("s1").rows(What::Causes, By::Cost)[0].name.clone();
        let by_time = one("s1").rows(What::Causes, By::Time)[0].name.clone();
        assert_eq!((by_cost.as_str(), by_time.as_str()), ("Tasks from the lead", "Bash"));
    }

    #[test]
    fn many_sessions_add_up_and_count_each_session_once() {
        let r = many();
        let single = one("s1");
        assert_eq!(r.sessions, 2);
        assert_eq!(r.cost_micros, single.cost_micros * 2);
        let sed = r.rows(What::Commands, By::Cost).into_iter().find(|c| c.name == "sed").unwrap();
        assert_eq!((sed.count, sed.sessions), (4, 2));
        let projects = r.rows(What::Projects, By::Cost);
        assert_eq!(projects.len(), 2);
        let sessions = r.rows(What::Sessions, By::Cost);
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].id.as_deref(), Some("s1"));
        // Turns keep their session, so an agent can open them.
        let turns = r.rows(What::Turns, By::Cost);
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[0].id.as_deref(), Some("1"));
        assert!(turns[0].session.is_some());
    }

    #[test]
    fn one_session_lists_its_subagents_and_many_add_them_up_by_type() {
        let lanes = one("s1").rows(What::Agents, By::Cost);
        assert_eq!(lanes[0].name, "Check prices");
        assert_eq!(lanes[0].id.as_deref(), Some("a1"));
        assert_eq!(lanes[0].detail.as_deref(), Some("reviewer on claude-opus-5-5"));
        let kinds = many().rows(What::Agents, By::Cost);
        assert_eq!(kinds.len(), 1);
        assert_eq!(kinds[0].name, "reviewer on claude-opus-5-5");
        assert_eq!((kinds[0].count, kinds[0].sessions), (2, 2));
    }

    #[test]
    fn a_brief_is_short_and_has_no_long_tip_texts() {
        let b = many().brief();
        assert_eq!(b.sessions, 2);
        assert_eq!(b.session_id, None);
        assert!(b.causes.len() <= 5 && b.commands.len() <= 5 && b.agents.len() <= 3 && b.turns.len() <= 3);
        assert_eq!(b.top_sessions.len(), 2);
        assert!(b.tips.iter().all(|t| t.detail.is_none()));
        let single = one("s1").brief();
        assert_eq!(single.session_id.as_deref(), Some("s1"));
        assert_eq!(single.title.as_deref(), Some("Cart fix"));
        assert!(single.top_sessions.is_empty() && single.projects.is_empty());
    }

    #[test]
    fn an_empty_rollup_gives_empty_rows() {
        let r = Rollup::default();
        assert!(r.rows(What::Commands, By::Cost).is_empty());
        let b = r.brief();
        assert_eq!((b.sessions, b.cost_micros), (0, 0));
    }

    #[test]
    fn what_and_by_are_read_from_text() {
        assert_eq!(What::parse("commands"), Ok(What::Commands));
        assert!(What::parse("nothing").is_err());
        assert_eq!(By::parse("time"), Ok(By::Time));
        assert!(By::parse("speed").is_err());
    }

    #[test]
    fn a_cause_report_lists_the_costliest_calls_of_a_tool_or_a_program() {
        let a = anatomy("s1");
        let bash = cause_report(&a, "bash", By::Cost, 2).unwrap();
        assert_eq!(bash.name, "Bash");
        assert_eq!((bash.total_calls, bash.calls.len(), bash.errors), (3, 2, 1));
        assert!(bash.calls[0].cost_micros >= bash.calls[1].cost_micros);
        assert_eq!(bash.calls[0].tool_use_id.as_deref(), Some("t3"));
        assert_eq!(bash.calls[0].lane_name, "Main session");
        assert!(bash.calls[0].is_error);

        let sed = cause_report(&a, "sed", By::Time, 10).unwrap();
        assert_eq!((sed.name.as_str(), sed.total_calls), ("sed", 2));
        assert_eq!(sed.calls[0].tool_use_id.as_deref(), Some("t1"), "2 s against 1 s");

        let prompts = cause_report(&a, "prompts", By::Cost, 10).unwrap();
        assert_eq!(prompts.name, "Your prompts");
        assert_eq!(prompts.calls[0].text.as_deref(), Some("fix the cart"));
        assert_eq!(cause_report(&a, "tasks", By::Cost, 10).unwrap().calls[0].lane, "a1");
    }

    #[test]
    fn an_unknown_cause_lists_what_there_is() {
        let names = cause_report(&anatomy("s1"), "Grep", By::Cost, 10).unwrap_err();
        assert!(names.contains(&"Bash".to_string()) && names.contains(&"sed".to_string()), "{names:?}");
    }
}
