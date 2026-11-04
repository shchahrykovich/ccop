//! The anatomy of one session: what happened when, in the main session and
//! in each subagent. `ccop anatomy <id> --json` prints it; the app shows it
//! as a timeline (apps/menubar/Sources/CCOPKit/Anatomy.swift decodes it).
//!
//! A lane is one transcript file: the main session, or one subagent
//! (`<id>/subagents/agent-<agent id>.jsonl`). A lane's events:
//! - `prompt`: a message a person (or, in a subagent, the lead) sent.
//! - `answer`: one call to the model. It starts when the previous event of
//!   the lane ended (the request went out then) and ends at its last line.
//! - `tool`: a tool call, from the answer that asked for it to its result.
//! - `compact`: the conversation was compacted.
//! - `error`: an API error Claude Code recorded.
//!
//! A subagent is linked to the `Agent` tool call that started it by its
//! `agent-<id>.meta.json` (`toolUseId`), or else by the tool result's
//! `toolUseResult.agentId`.

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::spend::{Refusal, refusal};
use crate::transcript::prompt_text;
use crate::usage::Usage;

/// The longest text kept for a tool input or an answer's text.
pub const SUMMARY_CHARS: usize = 160;

/// The longest text kept for a failed tool call's error.
pub const ERROR_CHARS: usize = 300;

/// The longest text kept for a Bash call's command (the whole one: `ccop call`).
pub const COMMAND_CHARS: usize = 300;

/// How many of the largest context contributors are kept.
pub const CONTRIBUTORS: usize = 25;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Anatomy {
    pub session_id: String,
    pub started_at: Option<DateTime<Utc>>,
    pub ended_at: Option<DateTime<Utc>>,
    /// The main session first, then the subagents by start time.
    pub lanes: Vec<Lane>,
    pub turns: Vec<Turn>,
    /// By tool name, the most calls first.
    pub tools: Vec<ToolStat>,
    /// The events that added the most tokens to a context, the most first.
    pub contributors: Vec<Contributor>,
    /// Where the cost went, and what to change (see `spend.rs`).
    pub spend: crate::spend::Spend,
}

/// One event that added tokens to its lane's context.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Contributor {
    pub lane: String,
    /// Index into the lane's `events`.
    pub event: usize,
    pub tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Lane {
    /// `main`, or the subagent's agent id.
    pub id: String,
    /// The lane whose tool call started this one.
    pub parent: Option<String>,
    /// The `Agent` tool call that started this lane.
    pub tool_use_id: Option<String>,
    /// `Main session`, or the subagent's description.
    pub name: String,
    pub agent_type: Option<String>,
    /// The model with the most calls in this lane.
    pub model: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
    pub ended_at: Option<DateTime<Utc>>,
    pub usage: Usage,
    pub tool_calls: u64,
    pub errors: u64,
    pub events: Vec<Event>,
    /// The context at each model call, split into parts (see `context.rs`).
    pub context: Vec<ContextPoint>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContextPoint {
    pub at: DateTime<Utc>,
    /// Index into the lane's `events`: the answer of this call.
    pub event: usize,
    /// Input tokens of the call: new, cache write and cache read. Exact.
    pub total: u64,
    /// `total` split by what put it there. Estimated; adds up to `total`.
    pub parts: Vec<ContextPart>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContextPart {
    pub name: String,
    pub tokens: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EventKind {
    Prompt,
    Answer,
    Tool,
    Compact,
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Event {
    pub kind: EventKind,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// Prompt: its text. Answer: the start of its text. Tool: a short form
    /// of its input. Compact and error: what happened.
    pub text: Option<String>,
    /// Answer: the model.
    pub model: Option<String>,
    /// Answer: its tokens. Compact: `input_tokens` is the context before.
    pub usage: Option<Usage>,
    /// Tool: its name.
    pub tool: Option<String>,
    pub tool_use_id: Option<String>,
    /// Tool: the result was an error.
    pub is_error: bool,
    /// Tool: the size of the result the model got back; None while it had none.
    pub result_bytes: Option<u64>,
    /// Tool: the subagent this call started.
    pub agent_id: Option<String>,
    /// Answer: the size of the context the model read for this call.
    pub context_tokens: Option<u64>,
    /// Prompt, tool or compact: the tokens it added to the context of the
    /// next call (a compact: what the summary put back). Estimated.
    pub added_tokens: Option<u64>,
    /// Bash: the program it ran, as `command_group` names it (`sed`, `node build.js context`).
    pub group: Option<String>,
    /// A failed tool call: the start of its error text, on one line.
    pub error: Option<String>,
    /// A command Claude Code refused to run in a worktree session: what kind.
    pub refusal: Option<Refusal>,
    /// Bash: the start of its command, on one line.
    pub command: Option<String>,
    /// Answer: the API-equivalent cost of the call. Tool, prompt or
    /// compaction: its part of the model call after it (see `spend::Cause`).
    pub cost_micros: Option<u64>,
    /// Prompt, tool or compaction: its part of the tokens of the model call
    /// after it (input, cache write, cache read and output), split as
    /// `cost_micros` is. None for an answer: its tokens are in `usage`.
    pub paid_tokens: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Turn {
    /// 1 for the first prompt; 0 for events before the first prompt.
    pub index: u64,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub prompt: String,
    /// Tokens of the main session in this turn.
    pub usage: Usage,
    /// Tokens of the subagents started in this turn.
    pub subagent_usage: Usage,
    /// API-equivalent cost of the main session's calls in this turn.
    pub cost_micros: u64,
    /// The same for the subagents started in this turn.
    pub subagent_cost_micros: u64,
    pub answers: u64,
    pub tool_calls: u64,
    /// Lane ids of the subagents started in this turn.
    pub subagents: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolStat {
    pub tool: String,
    pub calls: u64,
    pub errors: u64,
    /// The time from the calls to their results, added up.
    pub total_ms: u64,
    pub result_bytes: u64,
}

/// What `agent-<id>.meta.json` says about a subagent.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaneMeta {
    pub agent_type: Option<String>,
    pub description: Option<String>,
    pub tool_use_id: Option<String>,
}

/// Reads the lines of one lane's file.
pub struct LaneReader {
    lane: Lane,
    /// The answer of the last usage line: `message.id requestId` and its event.
    answer: Option<(String, usize)>,
    /// Tool calls without a result yet: tool_use_id → event.
    pending: HashMap<String, usize>,
    /// Bash calls without a result yet: tool_use_id → command, to tell what
    /// kind of command a refusal was about.
    commands: HashMap<String, String>,
    /// When the last event of the lane ended: the next answer starts here.
    last: Option<DateTime<Utc>>,
    models: BTreeMap<String, u64>,
    /// The full texts of the events, when asked for (`with_chat`): event → texts.
    chat: Option<BTreeMap<usize, ChatText>>,
}

/// The longest tool output kept for the chat; the whole one: `ccop call`.
pub const CHAT_OUTPUT_CHARS: usize = 4_000;

/// The full texts of one event, for the app's Chat tab (`ccop chat`). The
/// event's tokens and cost are in the anatomy, at the same index.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ChatText {
    /// The index in `Lane.events`.
    pub event: usize,
    /// Prompt: its whole text. Answer: its text blocks, one after another.
    pub text: Option<String>,
    /// Answer: it had thinking blocks. Their text is not in the transcript,
    /// but their tokens are in `output_tokens`.
    pub thinking: bool,
    /// Tool: the input as the model wrote it.
    pub input: Option<Value>,
    /// Tool: the start of its result, up to `CHAT_OUTPUT_CHARS`.
    pub output: Option<String>,
    /// The result is longer than `output`.
    pub output_truncated: bool,
}

impl LaneReader {
    /// Also keep the full texts of the events (`finish_with_chat`).
    pub fn with_chat(mut self) -> LaneReader {
        self.chat = Some(BTreeMap::new());
        self
    }

    fn chat_entry(&mut self, event: usize) -> Option<&mut ChatText> {
        self.chat.as_mut().map(|c| c.entry(event).or_insert_with(|| ChatText { event, ..ChatText::default() }))
    }

    pub fn main() -> LaneReader {
        LaneReader::new("main".into(), "Main session".into(), None, None)
    }

    pub fn subagent(agent_id: &str, meta: LaneMeta) -> LaneReader {
        let name = meta.description.clone().filter(|d| !d.is_empty()).unwrap_or_else(|| format!("Subagent {agent_id}"));
        LaneReader::new(agent_id.into(), name, meta.agent_type, meta.tool_use_id)
    }

    fn new(id: String, name: String, agent_type: Option<String>, tool_use_id: Option<String>) -> LaneReader {
        LaneReader {
            lane: Lane {
                id,
                parent: None,
                tool_use_id,
                name,
                agent_type,
                model: None,
                started_at: None,
                ended_at: None,
                usage: Usage::default(),
                tool_calls: 0,
                errors: 0,
                events: Vec::new(),
                context: Vec::new(),
            },
            answer: None,
            pending: HashMap::new(),
            commands: HashMap::new(),
            last: None,
            models: BTreeMap::new(),
            chat: None,
        }
    }

    pub fn feed(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        let Ok(r) = serde_json::from_str::<Value>(line) else { return };
        let Some(at) = r.get("timestamp").and_then(Value::as_str).and_then(|t| t.parse::<DateTime<Utc>>().ok()) else {
            return;
        };
        let lane = &mut self.lane;
        lane.started_at = Some(lane.started_at.map_or(at, |s| s.min(at)));
        lane.ended_at = Some(lane.ended_at.map_or(at, |e| e.max(at)));
        match r.get("type").and_then(Value::as_str) {
            Some("assistant") => self.answer(&r, at),
            Some("user") => self.user(&r, at),
            Some("system") => self.system(&r, at),
            _ => {}
        }
    }

    fn push(&mut self, kind: EventKind, start: DateTime<Utc>, end: DateTime<Utc>) -> usize {
        self.lane.events.push(Event {
            kind,
            start,
            end,
            text: None,
            model: None,
            usage: None,
            tool: None,
            tool_use_id: None,
            is_error: false,
            result_bytes: None,
            agent_id: None,
            context_tokens: None,
            added_tokens: None,
            group: None,
            error: None,
            refusal: None,
            command: None,
            cost_micros: None,
            paid_tokens: None,
        });
        self.lane.events.len() - 1
    }

    fn answer(&mut self, r: &Value, at: DateTime<Utc>) {
        let m = &r["message"];
        let model = m.get("model").and_then(Value::as_str).unwrap_or_default().to_string();
        if model == "<synthetic>" {
            return;
        }
        let id = m.get("id").and_then(Value::as_str).unwrap_or_default();
        let request = r.get("requestId").and_then(Value::as_str).unwrap_or_default();
        let key = format!("{id} {request}");
        let same = (!id.is_empty() || !request.is_empty()) && self.answer.as_ref().is_some_and(|(k, _)| *k == key);
        let i = if same {
            let i = self.answer.as_ref().unwrap().1;
            self.lane.events[i].end = at;
            i
        } else {
            let start = self.last.unwrap_or(at).min(at);
            let i = self.push(EventKind::Answer, start, at);
            self.lane.events[i].model = Some(model.clone()).filter(|m| !m.is_empty());
            *self.models.entry(model).or_default() += 1;
            self.answer = Some((key, i));
            i
        };
        if let Some(u) = m.get("usage") {
            let n = |k: &str| u.get(k).and_then(Value::as_u64).unwrap_or(0);
            let usage = Usage {
                input_tokens: n("input_tokens"),
                cache_write_tokens: n("cache_creation_input_tokens"),
                cache_write_1h_tokens: u
                    .get("cache_creation")
                    .and_then(|c| c.get("ephemeral_1h_input_tokens"))
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
                cache_read_tokens: n("cache_read_input_tokens"),
                output_tokens: n("output_tokens"),
                requests: 1,
            };
            if let Some(old) = self.lane.events[i].usage.replace(usage) {
                self.lane.usage -= old;
            }
            self.lane.usage += usage;
        }
        for block in m.get("content").and_then(Value::as_array).into_iter().flatten() {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => {
                    let t = block.get("text").and_then(Value::as_str).unwrap_or_default();
                    if self.lane.events[i].text.is_none() {
                        self.lane.events[i].text = Some(clip(t, SUMMARY_CHARS)).filter(|t| !t.is_empty());
                    }
                    if let Some(c) = self.chat_entry(i).filter(|_| !t.trim().is_empty()) {
                        c.text = Some(match c.text.take() {
                            Some(before) => format!("{before}\n\n{}", t.trim()),
                            None => t.trim().to_string(),
                        });
                    }
                }
                Some("thinking") | Some("redacted_thinking") => {
                    if let Some(c) = self.chat_entry(i) {
                        c.thinking = true;
                    }
                }
                Some("tool_use") => {
                    let name = block.get("name").and_then(Value::as_str).unwrap_or("tool").to_string();
                    let use_id = block.get("id").and_then(Value::as_str).unwrap_or_default().to_string();
                    if !use_id.is_empty() && self.pending.contains_key(&use_id) {
                        continue;
                    }
                    let t = self.push(EventKind::Tool, at, at);
                    let e = &mut self.lane.events[t];
                    e.text = tool_summary(&name, block.get("input").unwrap_or(&Value::Null));
                    let command = (name == "Bash").then(|| block["input"].get("command").and_then(Value::as_str).unwrap_or_default());
                    if let Some(c) = command {
                        e.group = Some(command_group(c));
                        e.command = Some(clip(c, COMMAND_CHARS)).filter(|c| !c.is_empty());
                    }
                    e.tool = Some(name);
                    e.tool_use_id = Some(use_id.clone()).filter(|u| !u.is_empty());
                    self.lane.tool_calls += 1;
                    if !use_id.is_empty() {
                        if let Some(c) = command {
                            self.commands.insert(use_id.clone(), c.to_string());
                        }
                        self.pending.insert(use_id, t);
                    }
                    if let Some(c) = self.chat_entry(t) {
                        c.input = block.get("input").cloned();
                    }
                }
                _ => {}
            }
        }
        self.last = Some(self.last.map_or(at, |l| l.max(at)));
    }

    fn user(&mut self, r: &Value, at: DateTime<Utc>) {
        let content = &r["message"]["content"];
        let results: Vec<&Value> = content
            .as_array()
            .map(|parts| parts.iter().filter(|p| p.get("type").and_then(Value::as_str) == Some("tool_result")).collect())
            .unwrap_or_default();
        if !results.is_empty() {
            let agent_id = r.get("toolUseResult").and_then(|t| t.get("agentId")).and_then(Value::as_str);
            for res in results {
                let Some(id) = res.get("tool_use_id").and_then(Value::as_str) else { continue };
                let Some(i) = self.pending.remove(id) else { continue };
                let command = self.commands.remove(id).unwrap_or_default();
                let error = res.get("is_error").and_then(Value::as_bool).unwrap_or(false);
                let e = &mut self.lane.events[i];
                e.end = at.max(e.start);
                e.is_error = error;
                e.result_bytes = Some(result_bytes(res.get("content").unwrap_or(&Value::Null)));
                if let Some(a) = agent_id {
                    e.agent_id = Some(a.to_string());
                }
                if error {
                    self.lane.errors += 1;
                    let text = result_text(res.get("content").unwrap_or(&Value::Null));
                    e.refusal = refusal(&command, &text);
                    e.error = Some(clip(&text, ERROR_CHARS)).filter(|t| !t.is_empty());
                }
                if let Some(c) = self.chat_entry(i) {
                    let text = crate::call::output_text(res.get("content").unwrap_or(&Value::Null));
                    c.output_truncated = text.chars().count() > CHAT_OUTPUT_CHARS;
                    c.output = Some(if c.output_truncated { text.chars().take(CHAT_OUTPUT_CHARS).collect() } else { text });
                }
            }
            self.last = Some(self.last.map_or(at, |l| l.max(at)));
            return;
        }
        // Not a prompt, but the next model call goes out after it: a subagent's
        // hand-back can come long after the last answer.
        let waited = self.last.map_or(at, |l| l.max(at));
        if r.get("isMeta").and_then(Value::as_bool) == Some(true) || r.get("isCompactSummary").and_then(Value::as_bool) == Some(true) {
            self.last = Some(waited);
            return;
        }
        let Some(text) = prompt_text(&content.to_string()) else {
            self.last = Some(waited);
            return;
        };
        let i = self.push(EventKind::Prompt, at, at);
        // The chat keeps the whole prompt; a slash command stays in its short form.
        let full = match content {
            Value::String(s) => s.trim().to_string(),
            Value::Array(parts) => parts.iter().filter_map(|p| p.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n").trim().to_string(),
            _ => String::new(),
        };
        let full = if full.is_empty() || full.contains("<command-name>") { text.clone() } else { full };
        if let Some(c) = self.chat_entry(i) {
            c.text = Some(full);
        }
        self.lane.events[i].text = Some(text);
        self.last = Some(at);
    }

    fn system(&mut self, r: &Value, at: DateTime<Utc>) {
        match r.get("subtype").and_then(Value::as_str) {
            Some("compact_boundary") => {
                let meta = &r["compactMetadata"];
                let pre = meta.get("preTokens").and_then(Value::as_u64).unwrap_or(0);
                let post = meta.get("postTokens").and_then(Value::as_u64);
                let trigger = meta.get("trigger").and_then(Value::as_str).unwrap_or("manual");
                let ms = meta.get("durationMs").and_then(Value::as_i64).unwrap_or(0);
                let start = at - chrono::Duration::milliseconds(ms);
                let i = self.push(EventKind::Compact, start.max(self.last.unwrap_or(start)).min(at), at);
                let after = post.map(|p| format!(" → {}", crate::usage::short(p))).unwrap_or_default();
                self.lane.events[i].text = Some(format!("Compacted ({trigger}): {}{after} tokens", crate::usage::short(pre)));
                self.lane.events[i].usage = Some(Usage { input_tokens: pre, ..Usage::default() });
                self.last = Some(at);
            }
            Some("api_error") => {
                let i = self.push(EventKind::Error, at, at);
                let text = r.get("content").and_then(Value::as_str).map(|c| clip(c, SUMMARY_CHARS));
                self.lane.events[i].text = text.or_else(|| Some("API error".into()));
                self.lane.events[i].is_error = true;
            }
            _ => {}
        }
    }

    pub fn finish(self) -> Lane {
        self.finish_with_chat().0
    }

    /// The lane, and the full texts of its events when `with_chat` asked for them.
    pub fn finish_with_chat(mut self) -> (Lane, Vec<ChatText>) {
        self.lane.model = self.models.iter().filter(|(m, _)| !m.is_empty()).max_by_key(|(_, n)| **n).map(|(m, _)| m.clone());
        crate::context::analyze(&mut self.lane);
        let chat = self.chat.take().map(|c| c.into_values().collect()).unwrap_or_default();
        (self.lane, chat)
    }
}

/// The lanes of one session into its anatomy: links subagents to the tool
/// calls that started them, and splits the main lane into turns.
pub fn build(session_id: &str, main: Lane, mut subagents: Vec<Lane>) -> Anatomy {
    subagents.sort_by(|a, b| a.started_at.cmp(&b.started_at).then(a.id.cmp(&b.id)));
    let mut lanes = vec![main];
    lanes.extend(subagents);

    // tool_use_id → (lane index, event index), and agent id → the same.
    let mut by_use: HashMap<String, (usize, usize)> = HashMap::new();
    let mut by_agent: HashMap<String, (usize, usize)> = HashMap::new();
    for (l, lane) in lanes.iter().enumerate() {
        for (e, ev) in lane.events.iter().enumerate() {
            if let Some(u) = &ev.tool_use_id {
                by_use.insert(u.clone(), (l, e));
            }
            if let Some(a) = &ev.agent_id {
                by_agent.insert(a.clone(), (l, e));
            }
        }
    }
    for l in 1..lanes.len() {
        let id = lanes[l].id.clone();
        let found = lanes[l].tool_use_id.as_ref().and_then(|u| by_use.get(u)).or_else(|| by_agent.get(&id)).copied();
        if let Some((pl, pe)) = found {
            lanes[l].parent = Some(lanes[pl].id.clone());
            let use_id = lanes[pl].events[pe].tool_use_id.clone();
            lanes[l].tool_use_id = lanes[l].tool_use_id.take().or(use_id);
            lanes[pl].events[pe].agent_id = Some(id);
        }
    }

    let turns = turns(&lanes);
    let mut stats: BTreeMap<String, ToolStat> = BTreeMap::new();
    for ev in lanes.iter().flat_map(|l| &l.events).filter(|e| e.kind == EventKind::Tool) {
        let name = ev.tool.clone().unwrap_or_default();
        let s = stats.entry(name.clone()).or_insert(ToolStat { tool: name, calls: 0, errors: 0, total_ms: 0, result_bytes: 0 });
        s.calls += 1;
        s.errors += ev.is_error as u64;
        s.total_ms += (ev.end - ev.start).num_milliseconds().max(0) as u64;
        s.result_bytes += ev.result_bytes.unwrap_or(0);
    }
    let mut tools: Vec<ToolStat> = stats.into_values().collect();
    tools.sort_by(|a, b| b.calls.cmp(&a.calls).then(a.tool.cmp(&b.tool)));
    let mut contributors: Vec<Contributor> = lanes
        .iter()
        .flat_map(|l| {
            l.events.iter().enumerate().filter(|(_, e)| e.kind != EventKind::Compact).filter_map(move |(i, e)| {
                e.added_tokens.filter(|t| *t > 0).map(|tokens| Contributor { lane: l.id.clone(), event: i, tokens })
            })
        })
        .collect();
    contributors.sort_by(|a, b| b.tokens.cmp(&a.tokens).then(a.lane.cmp(&b.lane)).then(a.event.cmp(&b.event)));
    contributors.truncate(CONTRIBUTORS);
    let (spend, paid) = crate::spend::analyze_with_paid(&lanes);
    for (li, lane) in lanes.iter_mut().enumerate() {
        for (ei, e) in lane.events.iter_mut().enumerate() {
            let p = paid.get(&(li, ei));
            e.cost_micros = match e.kind {
                EventKind::Answer => Some(crate::spend::event_cost(e)),
                _ => p.map(|p| p.cost_micros.round() as u64),
            };
            e.paid_tokens = match e.kind {
                EventKind::Answer => None,
                _ => p.map(|p| p.tokens.round() as u64),
            };
        }
    }
    Anatomy {
        session_id: session_id.to_string(),
        started_at: lanes.iter().filter_map(|l| l.started_at).min(),
        ended_at: lanes.iter().filter_map(|l| l.ended_at).max(),
        lanes,
        turns,
        tools,
        contributors,
        spend,
    }
}

/// Each prompt of the main lane starts a turn; a subagent belongs to the
/// turn in which its top-level ancestor started.
fn turns(lanes: &[Lane]) -> Vec<Turn> {
    let main = &lanes[0];
    let mut out: Vec<Turn> = Vec::new();
    for ev in &main.events {
        if ev.kind == EventKind::Prompt {
            let index = out.iter().filter(|t| t.index > 0).count() as u64 + 1;
            out.push(Turn {
                index,
                start: ev.start,
                end: ev.end,
                prompt: ev.text.clone().unwrap_or_default(),
                usage: Usage::default(),
                subagent_usage: Usage::default(),
                cost_micros: 0,
                subagent_cost_micros: 0,
                answers: 0,
                tool_calls: 0,
                subagents: Vec::new(),
            });
            continue;
        }
        if out.is_empty() {
            out.push(Turn {
                index: 0,
                start: ev.start,
                end: ev.end,
                prompt: "(before the first prompt)".into(),
                usage: Usage::default(),
                subagent_usage: Usage::default(),
                cost_micros: 0,
                subagent_cost_micros: 0,
                answers: 0,
                tool_calls: 0,
                subagents: Vec::new(),
            });
        }
        let t = out.last_mut().unwrap();
        t.end = t.end.max(ev.end);
        match ev.kind {
            EventKind::Answer => {
                t.answers += 1;
                t.cost_micros += crate::spend::event_cost(ev);
                if let Some(u) = ev.usage {
                    t.usage += u;
                }
            }
            EventKind::Tool => t.tool_calls += 1,
            _ => {}
        }
    }
    if out.is_empty() {
        return out;
    }
    let index_of: HashMap<&str, usize> = lanes.iter().enumerate().map(|(i, l)| (l.id.as_str(), i)).collect();
    for lane in &lanes[1..] {
        // Up to the lane that main started.
        let mut top = lane;
        let mut hops = 0;
        while let Some(p) = top.parent.as_deref().filter(|p| *p != "main").and_then(|p| index_of.get(p)) {
            top = &lanes[*p];
            hops += 1;
            if hops > lanes.len() {
                break;
            }
        }
        let Some(start) = top.started_at else { continue };
        let k = out.iter().rposition(|t| t.start <= start).unwrap_or(0);
        let t = &mut out[k];
        t.subagent_usage += lane.usage;
        t.subagent_cost_micros += crate::spend::lane_cost(lane);
        t.subagents.push(lane.id.clone());
        if let Some(end) = lane.ended_at {
            t.end = t.end.max(end);
        }
    }
    out
}

/// A short form of a tool's input: the command, file, pattern or query.
pub fn tool_summary(name: &str, input: &Value) -> Option<String> {
    let s = |k: &str| input.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
    let text = match name {
        "Bash" => s("description").or(s("command")).map(str::to_string),
        "Read" | "Write" | "Edit" | "MultiEdit" | "NotebookEdit" => s("file_path").or(s("notebook_path")).map(str::to_string),
        "Grep" => s("pattern").map(|p| match s("path") {
            Some(path) => format!("{p} in {path}"),
            None => p.to_string(),
        }),
        "Glob" => s("pattern").map(str::to_string),
        "WebSearch" | "ToolSearch" => s("query").map(str::to_string),
        "WebFetch" => s("url").map(str::to_string),
        "Agent" | "Task" => s("description").map(|d| match s("subagent_type") {
            Some(t) => format!("{d} ({t})"),
            None => d.to_string(),
        }),
        "Skill" => s("skill").map(str::to_string),
        "SendMessage" => s("to").map(|to| format!("to {to}")),
        _ => None,
    };
    // Any other tool: its first text field.
    let text = text.or_else(|| input.as_object()?.values().find_map(|v| v.as_str().filter(|v| !v.is_empty()).map(str::to_string)))?;
    if matches!(name, "Read" | "Write" | "Edit" | "MultiEdit" | "NotebookEdit") {
        // A long path keeps its end: the file's name says more than its start.
        return Some(clip_start(&text, SUMMARY_CHARS));
    }
    Some(clip(&text, SUMMARY_CHARS))
}

/// The last `max` characters, with `…` in front when cut.
fn clip_start(text: &str, max: usize) -> String {
    let n = text.chars().count();
    if n <= max {
        return text.to_string();
    }
    let tail: String = text.chars().skip(n - (max - 1)).collect();
    format!("…{tail}")
}

/// The program a Bash command runs, so calls can be counted by it:
/// `sed`, `grep`, `node build.js context`, `python3 (inline script)`,
/// `git commit`, `for loop`. Leading `cd <dir> &&`, `VAR=value` and `rtk`
/// are skipped; only the first command of a pipe or list counts.
pub fn command_group(command: &str) -> String {
    let first_line = command.trim().lines().next().unwrap_or_default();
    let mut words: Vec<&str> = first_line.split_whitespace().collect();
    // `cd <dir> &&`, `cd <dir>;`, `VAR=value;`, `VAR="$(...)" &&` and `VAR=value cmd` before the command.
    loop {
        let Some(w) = words.first().copied() else { return "(empty)".into() };
        let assignment = w.split_once('=').filter(|(name, _)| !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'));
        if w == "cd" {
            match words.iter().position(|x| *x == "&&" || *x == ";" || x.ends_with(';')) {
                Some(i) => drop(words.drain(..=i)),
                None => return "cd".into(),
            }
        } else if let Some((_, value)) = assignment {
            // A quoted value can hold spaces: it ends at the word with the closing quote.
            let mut end = 0;
            if let Some(q) = value.chars().next().filter(|c| *c == '"' || *c == '\'') {
                let closes = |t: &str| t.trim_end_matches(';').ends_with(q);
                if !(value.len() > 1 && closes(value)) {
                    end = words.iter().skip(1).position(|t| closes(t)).map_or(words.len() - 1, |p| p + 1);
                }
            }
            words.drain(..=end);
            if words.first().is_some_and(|x| *x == "&&" || *x == ";") {
                words.remove(0);
            }
        } else if w == "rtk" {
            words.remove(0);
        } else {
            break;
        }
    }
    let w0 = words[0];
    if matches!(w0, "for" | "while" | "until") {
        return format!("{w0} loop");
    }
    if w0.starts_with('$') {
        return "(program in a variable)".into();
    }
    let program = w0.rsplit('/').next().unwrap_or(w0).trim_end_matches(';');
    let plain = |w: &str| !w.is_empty() && w.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == ':');
    match program {
        "node" | "python" | "python3" | "ruby" | "deno" | "bun" | "bash" | "sh" | "zsh" | "perl" => {
            let rest: Vec<&str> = words[1..].iter().copied().skip_while(|w| w.starts_with('-') && *w != "-" && *w != "-c" && *w != "-e").collect();
            match rest.first() {
                None => program.to_string(),
                Some(&"-") | Some(&"-c") | Some(&"-e") => format!("{program} (inline script)"),
                Some(w) if w.starts_with("<<") => format!("{program} (inline script)"),
                Some(w) if w.starts_with('$') => format!("{program} (path in a variable)"),
                Some(script) => {
                    let name = script.rsplit('/').next().unwrap_or(script);
                    match rest.get(1).filter(|w| plain(w)) {
                        Some(sub) => format!("{program} {name} {sub}"),
                        None => format!("{program} {name}"),
                    }
                }
            }
        }
        "git" | "npm" | "pnpm" | "yarn" | "cargo" | "gh" | "docker" | "swift" | "go" | "kubectl" | "brew" | "make" => {
            let mut rest = words[1..].iter();
            while let Some(w) = rest.next() {
                if matches!(*w, "-c" | "-C" | "--git-dir" | "--work-tree" | "-p" | "--package") {
                    rest.next();
                } else if !w.starts_with('-') {
                    return if plain(w) { format!("{program} {w}") } else { program.to_string() };
                }
            }
            program.to_string()
        }
        _ => program.to_string(),
    }
}

/// The text a tool gave back, on one line.
fn result_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts.iter().filter_map(|p| p.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join(" "),
        _ => String::new(),
    }
}

/// Bytes of text a tool gave back; an image counts as its base64 data.
pub fn result_bytes(content: &Value) -> u64 {
    match content {
        Value::String(s) => s.len() as u64,
        Value::Array(parts) => parts
            .iter()
            .map(|p| {
                p.get("text")
                    .and_then(Value::as_str)
                    .or_else(|| p.get("source").and_then(|s| s.get("data")).and_then(Value::as_str))
                    .map_or(0, |t| t.len() as u64)
            })
            .sum(),
        Value::Null => 0,
        other => other.to_string().len() as u64,
    }
}

fn clip(text: &str, max: usize) -> String {
    let one_line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= max {
        one_line
    } else {
        let mut s: String = one_line.chars().take(max - 1).collect();
        s.push('…');
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn at(s: &str) -> DateTime<Utc> {
        format!("2026-11-02T10:{s}Z").parse().unwrap()
    }

    fn lane(reader: LaneReader, lines: &[Value]) -> Lane {
        let mut r = reader;
        for l in lines {
            r.feed(&l.to_string());
        }
        r.finish()
    }

    fn prompt(t: &str, text: &str) -> Value {
        json!({"type": "user", "timestamp": format!("2026-11-02T10:{t}Z"), "message": {"content": text}})
    }

    fn answer(t: &str, id: &str, out: u64, blocks: Value) -> Value {
        json!({"type": "assistant", "requestId": format!("r{id}"), "timestamp": format!("2026-11-02T10:{t}Z"),
               "message": {"id": id, "model": "claude-opus-5-5", "content": blocks,
                           "usage": {"input_tokens": 1, "cache_read_input_tokens": 100, "output_tokens": out}}})
    }

    fn result(t: &str, use_id: &str, text: &str, error: bool, extra: Value) -> Value {
        json!({"type": "user", "timestamp": format!("2026-11-02T10:{t}Z"), "toolUseResult": extra,
               "message": {"content": [{"type": "tool_result", "tool_use_id": use_id, "content": text, "is_error": error}]}})
    }

    /// A subagent's hand-back is a meta record. The next model call goes out
    /// then, not when the previous answer ended: the wait is not model time.
    #[test]
    fn an_answer_after_a_meta_record_starts_at_that_record() {
        let meta = json!({"type": "user", "isMeta": true, "timestamp": "2026-11-02T10:40:00Z", "message": {"content": "[Subagent hand-back] done"}});
        let l = lane(LaneReader::main(), &[prompt("00:00", "go"), answer("00:05", "m1", 1, json!([])), meta, answer("40:10", "m2", 1, json!([]))]);
        let second = l.events.iter().filter(|e| e.kind == EventKind::Answer).nth(1).unwrap();
        assert_eq!((second.start, second.end), (at("40:00"), at("40:10")));
    }

    #[test]
    fn the_chat_keeps_the_whole_texts_at_the_event_indices() {
        let long_prompt = format!("Write the report.\n\n{}", "Use the notes. ".repeat(30));
        let lines = [
            prompt("00:00", &long_prompt),
            // One answer in three lines: thinking, text, a tool call.
            answer("00:04", "m1", 10, json!([{"type": "thinking", "thinking": "", "signature": "x"}])),
            answer("00:04", "m1", 10, json!([{"type": "text", "text": "First I read the notes.\n\nThen I write."}])),
            answer("00:05", "m1", 10, json!([{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "cat notes/a.md", "description": "Read notes"}}])),
            result("00:07", "t1", &"n".repeat(CHAT_OUTPUT_CHARS + 1), false, json!({})),
            answer("00:08", "m2", 5, json!([{"type": "text", "text": "Done."}])),
            json!({"type": "user", "timestamp": "2026-11-02T10:00:09Z",
                   "message": {"content": "<command-name>/clear</command-name><command-args></command-args>"}}),
        ];
        let mut r = LaneReader::main().with_chat();
        for l in &lines {
            r.feed(&l.to_string());
        }
        let (lane, chat) = r.finish_with_chat();
        let kinds: Vec<EventKind> = lane.events.iter().map(|e| e.kind).collect();
        assert_eq!(kinds, [EventKind::Prompt, EventKind::Answer, EventKind::Tool, EventKind::Answer, EventKind::Prompt]);
        assert_eq!(chat.iter().map(|c| c.event).collect::<Vec<_>>(), [0, 1, 2, 3, 4]);
        // The anatomy clips the prompt; the chat does not.
        assert!(lane.events[0].text.as_ref().unwrap().chars().count() < long_prompt.trim().chars().count());
        assert_eq!(chat[0].text.as_deref(), Some(long_prompt.trim()));
        assert!(chat[1].thinking);
        assert_eq!(chat[1].text.as_deref(), Some("First I read the notes.\n\nThen I write."));
        assert_eq!(chat[2].input.as_ref().unwrap()["command"], "cat notes/a.md");
        assert_eq!(chat[2].output.as_ref().unwrap().len(), CHAT_OUTPUT_CHARS);
        assert!(chat[2].output_truncated);
        assert!(!chat[3].thinking);
        assert_eq!(chat[3].text.as_deref(), Some("Done."));
        assert_eq!(chat[4].text.as_deref(), Some("/clear"));

        // Without `with_chat`, nothing is kept.
        let mut plain = LaneReader::main();
        for l in &lines {
            plain.feed(&l.to_string());
        }
        assert!(plain.finish_with_chat().1.is_empty());
    }

    #[test]
    fn a_session_with_tools_a_subagent_and_two_turns() {
        let main = lane(
            LaneReader::main(),
            &[
                prompt("00:00", "write the report"),
                answer("00:04", "m1", 10, json!([{"type": "text", "text": "Looking."}])),
                // The same answer, its next block: a tool call.
                answer("00:05", "m1", 10, json!([{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls", "description": "List files"}}])),
                result("00:07", "t1", "a\nb", false, json!({})),
                answer("00:09", "m2", 20, json!([
                    {"type": "tool_use", "id": "t2", "name": "Agent", "input": {"description": "Research", "subagent_type": "general-purpose"}},
                    {"type": "tool_use", "id": "t3", "name": "Read", "input": {"file_path": "/p/x.md"}}])),
                result("00:10", "t2", "launched", false, json!({"agentId": "a1", "status": "async_launched"})),
                result("00:11", "t3", "no such file", true, json!({})),
                answer("00:15", "m3", 5, json!([{"type": "text", "text": "Done."}])),
                prompt("05:00", "push"),
                json!({"type": "system", "subtype": "compact_boundary", "timestamp": "2026-11-02T10:06:00Z",
                       "compactMetadata": {"trigger": "auto", "preTokens": 486327, "postTokens": 26461, "durationMs": 30000}}),
                answer("06:10", "m4", 1, json!([])),
            ],
        );
        let sub = lane(
            LaneReader::subagent("a1", LaneMeta::default()),
            &[
                json!({"type": "user", "isSidechain": true, "timestamp": "2026-11-02T10:00:10Z", "message": {"content": "Research the topic"}}),
                answer("00:30", "s1", 7, json!([{"type": "tool_use", "id": "u1", "name": "WebSearch", "input": {"query": "romance tropes"}}])),
                result("00:40", "u1", "results", false, json!({})),
                answer("01:00", "s2", 3, json!([])),
            ],
        );
        let a = build("s", main, vec![sub]);

        let m = &a.lanes[0];
        let kinds: Vec<EventKind> = m.events.iter().map(|e| e.kind).collect();
        use EventKind::*;
        assert_eq!(kinds, [Prompt, Answer, Tool, Answer, Tool, Tool, Answer, Prompt, Compact, Answer]);
        // The first answer started at the prompt and ended at its last line.
        assert_eq!((m.events[1].start, m.events[1].end, m.events[1].text.as_deref()), (at("00:00"), at("00:05"), Some("Looking.")));
        // Its usage counts once.
        assert_eq!(m.usage.output_tokens, 10 + 20 + 5 + 1);
        assert_eq!(m.usage.requests, 4);
        let bash = &m.events[2];
        assert_eq!((bash.text.as_deref(), bash.start, bash.end, bash.result_bytes), (Some("List files"), at("00:05"), at("00:07"), Some(3)));
        // The second answer started when the Bash result came.
        assert_eq!(m.events[3].start, at("00:07"));
        assert_eq!(m.events[4].agent_id.as_deref(), Some("a1"));
        assert_eq!((m.events[5].is_error, m.errors, m.tool_calls), (true, 1, 3));
        assert_eq!(m.events[8].text.as_deref(), Some("Compacted (auto): 486K → 26K tokens"));
        assert_eq!(m.events[8].start, at("05:30"));

        // The subagent is linked to the Agent call by the result's agentId.
        let s = &a.lanes[1];
        assert_eq!((s.parent.as_deref(), s.tool_use_id.as_deref(), s.name.as_str()), (Some("main"), Some("t2"), "Subagent a1"));
        assert_eq!((s.started_at, s.ended_at), (Some(at("00:10")), Some(at("01:00"))));
        assert_eq!(s.events[0].text.as_deref(), Some("Research the topic"));
        assert_eq!(s.model.as_deref(), Some("claude-opus-5-5"));

        assert_eq!(a.turns.len(), 2);
        let t1 = &a.turns[0];
        assert_eq!((t1.index, t1.prompt.as_str(), t1.answers, t1.tool_calls), (1, "write the report", 3, 3));
        assert_eq!((t1.subagents.clone(), t1.subagent_usage.output_tokens, t1.end), (vec!["a1".to_string()], 10, at("01:00")));
        assert_eq!((a.turns[1].index, a.turns[1].answers, a.turns[1].usage.output_tokens), (2, 1, 1));

        let names: Vec<(&str, u64, u64)> = a.tools.iter().map(|t| (t.tool.as_str(), t.calls, t.errors)).collect();
        assert_eq!(names, [("Agent", 1, 0), ("Bash", 1, 0), ("Read", 1, 1), ("WebSearch", 1, 0)]);
        assert_eq!(a.tools[1].total_ms, 2000);
        assert_eq!((a.started_at, a.ended_at), (Some(at("00:00")), Some(at("06:10"))));
    }

    #[test]
    fn the_meta_file_links_a_subagent_and_names_it() {
        let main = lane(
            LaneReader::main(),
            &[
                prompt("00:00", "go"),
                answer("00:01", "m1", 1, json!([{"type": "tool_use", "id": "toolu_9", "name": "Agent", "input": {"description": "Style sheet"}}])),
            ],
        );
        let meta: LaneMeta = serde_json::from_str(r#"{"agentType":"general-purpose","description":"Book 2: style sheet","toolUseId":"toolu_9","model":"opus"}"#).unwrap();
        let sub = lane(LaneReader::subagent("a9", meta), &[answer("00:02", "s1", 1, json!([]))]);
        let a = build("s", main, vec![sub]);
        let s = &a.lanes[1];
        assert_eq!((s.name.as_str(), s.agent_type.as_deref(), s.parent.as_deref()), ("Book 2: style sheet", Some("general-purpose"), Some("main")));
        assert_eq!(a.lanes[0].events[2].agent_id.as_deref(), Some("a9"));
        // The tool call has no result yet: it has no size.
        assert_eq!(a.lanes[0].events[2].result_bytes, None);
    }

    #[test]
    fn bash_commands_are_grouped_by_the_program_they_run() {
        let cases = [
            ("sed -n 1,30p docs/timeline.md; sed -n 20,100p a.md", "sed"),
            ("cd /p/site && grep -n 'x' docs/page-04.md | head", "grep"),
            ("cd /p && cd q; cat a.md", "cat"),
            ("/usr/bin/grep -n -i 'x' notes.md", "grep"),
            ("rtk ls logs/01-*/out", "ls"),
            ("node /p/.claude/skills/build/scripts/build.js context p04 .", "node build.js context"),
            ("node /p/build.js /p/docs", "node build.js"),
            ("python3 /p/scripts/lint_docs.py .", "python3 lint_docs.py"),
            ("python3 -I /p/scripts/check.py run", "python3 check.py run"),
            ("python3 - <<'EOF'\nprint(1)\nEOF", "python3 (inline script)"),
            ("python3 -c \"print(1)\"", "python3 (inline script)"),
            ("for f in docs/*.md; do wc -w $f; done", "for loop"),
            ("R=/p/x; S=$R/.claude; node $S/build.js check", "node (path in a variable)"),
            ("S=\"$(git rev-parse --show-toplevel)\" && ls $S", "ls"),
            ("git -c core.pager=cat -C /p log --oneline", "git log"),
            ("git commit -m x && git push", "git commit"),
            ("FOO=1 cargo test -p x", "cargo test"),
            ("  ", "(empty)"),
        ];
        for (command, group) in cases {
            assert_eq!(command_group(command), group, "{command}");
        }
    }

    #[test]
    fn a_failed_call_keeps_the_start_of_its_error() {
        let main = lane(
            LaneReader::main(),
            &[
                prompt("00:00", "go"),
                answer("00:01", "m1", 1, json!([{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "cd /p && sed -n 1p a.md", "description": "Read a"}}])),
                result("00:02", "t1", "Exit code 1\nsed: a.md: No such file or directory", true, json!({})),
            ],
        );
        let e = &main.events[2];
        assert_eq!(e.group.as_deref(), Some("sed"));
        assert_eq!(e.error.as_deref(), Some("Exit code 1 sed: a.md: No such file or directory"));
        assert_eq!(main.events[1].group, None);
    }

    #[test]
    fn tool_summaries() {
        assert_eq!(tool_summary("Bash", &json!({"command": "ls -la"})).as_deref(), Some("ls -la"));
        assert_eq!(tool_summary("Grep", &json!({"pattern": "fn main", "path": "src"})).as_deref(), Some("fn main in src"));
        assert_eq!(tool_summary("mcp__x__get", &json!({"id": 3, "name": "abc"})).as_deref(), Some("abc"));
        assert_eq!(tool_summary("Other", &json!({})), None);
        let long = format!("/Users/x/{}/notes/big.md", "d".repeat(200));
        let read = tool_summary("Read", &json!({"file_path": long})).unwrap();
        assert!(read.starts_with('…') && read.ends_with("/notes/big.md"), "{read}");
        assert_eq!(read.chars().count(), SUMMARY_CHARS);
        assert_eq!(result_bytes(&json!([{"type": "text", "text": "abcd"}, {"type": "image", "source": {"data": "xyz"}}])), 7);
    }
}
