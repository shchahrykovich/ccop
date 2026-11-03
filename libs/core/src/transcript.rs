//! Reads the lines of one Claude Code transcript file into a `Transcript`.
//! No I/O here: the caller gives the lines. The state can be saved and fed
//! more lines later, so a file that grows is read only from where it ended.
//!
//! Files: `~/.claude/projects/<folder>/<session id>.jsonl` and the
//! subagents of the session in `<session id>/subagents/agent-*.jsonl`.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

use crate::usage::Usage;

/// The longest prompt text kept, in characters.
pub const PROMPT_CHARS: usize = 300;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Transcript {
    pub session_id: Option<String>,
    /// The folder the session ran in; a `relocated` record moves it.
    pub cwd: Option<String>,
    /// The git branch of the newest record that has one.
    pub git_branch: Option<String>,
    /// The Claude Code version of the newest record that has one.
    pub version: Option<String>,
    /// The title Claude Code made for the session (the newest one).
    pub ai_title: Option<String>,
    /// The name the user gave the session (`/rename`).
    pub agent_name: Option<String>,
    pub first_prompt: Option<String>,
    pub last_prompt: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    /// Prompts a person typed (not tool results, not meta records).
    pub prompts: u64,
    /// Tokens by model.
    pub usage: BTreeMap<String, Usage>,
    /// API-equivalent cost of all calls, in millionths of a dollar (see `pricing.rs`).
    #[serde(default)]
    pub cost_micros: u64,
    /// Tokens and cost by the hour the answer came: key = Unix time / 3600.
    #[serde(default)]
    pub hours: BTreeMap<i64, HourUsage>,
    /// The session that continues this one, when there is one.
    pub continued_in: Option<String>,
    /// The answer of the last usage line, to count a repeated line once.
    /// The lines of one answer are always next to each other in the file.
    #[serde(default)]
    last_answer: Option<LastAnswer>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct LastAnswer {
    key: String,
    model: String,
    usage: Usage,
    #[serde(default)]
    cost_micros: u64,
    #[serde(default)]
    hour: Option<i64>,
}

/// Tokens and API-equivalent cost of the calls in one hour.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HourUsage {
    pub usage: Usage,
    pub cost_micros: u64,
}

impl HourUsage {
    pub fn add(&mut self, o: &HourUsage) {
        self.usage += o.usage;
        self.cost_micros += o.cost_micros;
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<DateTime<Utc>>,
    session_id: Option<String>,
    cwd: Option<String>,
    git_branch: Option<String>,
    version: Option<String>,
    request_id: Option<String>,
    #[serde(default)]
    is_meta: bool,
    #[serde(default)]
    is_sidechain: bool,
    #[serde(default)]
    is_compact_summary: bool,
    message: Option<Message>,
    ai_title: Option<String>,
    agent_name: Option<String>,
    last_prompt: Option<String>,
    relocated_cwd: Option<String>,
    continued_in_session_id: Option<String>,
}

#[derive(Deserialize)]
struct Message {
    id: Option<String>,
    model: Option<String>,
    usage: Option<RawUsage>,
    /// Parsed only for user records: an answer's content can be large.
    content: Option<Box<RawValue>>,
}

#[derive(Deserialize)]
struct RawUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_creation: Option<CacheCreation>,
}

#[derive(Deserialize)]
struct CacheCreation {
    #[serde(default)]
    ephemeral_1h_input_tokens: u64,
}

impl Transcript {
    /// Reads one line of the file. A line that is not a JSON record is skipped.
    pub fn feed(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        let Ok(r) = serde_json::from_str::<Record>(line) else { return };
        if let Some(t) = r.timestamp {
            self.started_at = Some(self.started_at.map_or(t, |s| s.min(t)));
            self.updated_at = Some(self.updated_at.map_or(t, |u| u.max(t)));
        }
        if self.session_id.is_none() {
            self.session_id = r.session_id.clone();
        }
        if self.cwd.is_none() {
            self.cwd = r.cwd.clone().filter(|c| !c.is_empty());
        }
        if let Some(b) = r.git_branch.as_ref().filter(|b| !b.is_empty()) {
            self.git_branch = Some(b.clone());
        }
        if let Some(v) = r.version.as_ref().filter(|v| !v.is_empty()) {
            self.version = Some(v.clone());
        }
        match r.kind.as_deref() {
            Some("assistant") => self.answer(&r),
            Some("user") => self.prompt(&r),
            Some("ai-title") => self.ai_title = r.ai_title.filter(|t| !t.is_empty()).or(self.ai_title.take()),
            Some("agent-name") => self.agent_name = r.agent_name.filter(|t| !t.is_empty()).or(self.agent_name.take()),
            Some("last-prompt") => {
                if let Some(p) = r.last_prompt.as_deref().map(clip).filter(|p| !p.is_empty()) {
                    self.last_prompt = Some(p);
                }
            }
            Some("relocated") => self.cwd = r.relocated_cwd.or(self.cwd.take()),
            Some("continued-in") => self.continued_in = r.continued_in_session_id,
            _ => {}
        }
    }

    fn answer(&mut self, r: &Record) {
        let Some(m) = &r.message else { return };
        let Some(u) = &m.usage else { return };
        let model = m.model.clone().unwrap_or_default();
        // An answer Claude Code makes itself, such as an error, costs nothing.
        if model == "<synthetic>" {
            return;
        }
        let usage = Usage {
            input_tokens: u.input_tokens,
            cache_write_tokens: u.cache_creation_input_tokens,
            cache_write_1h_tokens: u.cache_creation.as_ref().map_or(0, |c| c.ephemeral_1h_input_tokens),
            cache_read_tokens: u.cache_read_input_tokens,
            output_tokens: u.output_tokens,
            requests: 1,
        };
        let cost = crate::pricing::cost_micros(&model, &usage);
        let id = m.id.as_deref().unwrap_or_default();
        let request = r.request_id.as_deref().unwrap_or_default();
        let key = format!("{id} {request}");
        let repeat = !id.is_empty() || !request.is_empty();
        let mut hour = r.timestamp.map(|t| t.timestamp().div_euclid(3600));
        if let Some(last) = self.last_answer.take().filter(|l| repeat && l.key == key) {
            // The same answer again: its newest usage replaces the old one,
            // in the hour of its first line.
            *self.usage.entry(last.model.clone()).or_default() -= last.usage;
            self.cost_micros = self.cost_micros.saturating_sub(last.cost_micros);
            if let Some(h) = last.hour
                && let Some(b) = self.hours.get_mut(&h)
            {
                b.usage -= last.usage;
                b.cost_micros = b.cost_micros.saturating_sub(last.cost_micros);
            }
            hour = last.hour.or(hour);
        }
        *self.usage.entry(model.clone()).or_default() += usage;
        self.cost_micros += cost;
        if let Some(h) = hour {
            self.hours.entry(h).or_default().add(&HourUsage { usage, cost_micros: cost });
        }
        self.last_answer = Some(LastAnswer { key, model, usage, cost_micros: cost, hour });
    }

    fn prompt(&mut self, r: &Record) {
        if r.is_meta || r.is_sidechain || r.is_compact_summary {
            return;
        }
        let Some(content) = r.message.as_ref().and_then(|m| m.content.as_ref()) else { return };
        let Some(text) = prompt_text(content.get()) else { return };
        self.prompts += 1;
        if self.first_prompt.is_none() {
            self.first_prompt = Some(text.clone());
        }
        self.last_prompt = Some(text);
    }

    /// All tokens of this file, all models together.
    pub fn total(&self) -> Usage {
        let mut out = Usage::default();
        for u in self.usage.values() {
            out += *u;
        }
        out
    }
}

/// The text a person typed, from a user message's `content` (JSON). `None`
/// for tool results and for text Claude Code adds itself.
pub fn prompt_text(content_json: &str) -> Option<String> {
    let content: serde_json::Value = serde_json::from_str(content_json).ok()?;
    let text = match content {
        serde_json::Value::String(s) => s,
        serde_json::Value::Array(parts) => {
            let texts: Vec<&str> = parts
                .iter()
                .filter(|p| p.get("type").and_then(|t| t.as_str()) == Some("text"))
                .filter_map(|p| p.get("text").and_then(|t| t.as_str()))
                .collect();
            if texts.is_empty() {
                return None;
            }
            texts.join("\n")
        }
        _ => return None,
    };
    let text = text.trim();
    // A slash command: `<command-name>/init</command-name> ... <command-args>x</command-args>`.
    if let Some(name) = between(text, "<command-name>", "</command-name>") {
        let name = name.trim();
        let name = if name.starts_with('/') { name.to_string() } else { format!("/{name}") };
        let args = between(text, "<command-args>", "</command-args>").unwrap_or_default().trim();
        return Some(clip(&if args.is_empty() { name } else { format!("{name} {args}") }));
    }
    if let Some(cmd) = between(text, "<bash-input>", "</bash-input>") {
        return Some(clip(&format!("! {}", cmd.trim())));
    }
    const ADDED: [&str; 6] = [
        "<local-command-",
        "<bash-stdout>",
        "<bash-stderr>",
        "<system-reminder>",
        "<task-notification>",
        "[Request interrupted",
    ];
    if text.is_empty() || ADDED.iter().any(|p| text.starts_with(p)) || text.starts_with("Caveat: The messages below") {
        return None;
    }
    Some(clip(text))
}

fn between<'a>(text: &'a str, open: &str, close: &str) -> Option<&'a str> {
    let start = text.find(open)? + open.len();
    let end = text[start..].find(close)? + start;
    Some(&text[start..end])
}

/// The first `PROMPT_CHARS` characters, on one line.
fn clip(text: &str) -> String {
    let one_line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= PROMPT_CHARS {
        one_line
    } else {
        let mut s: String = one_line.chars().take(PROMPT_CHARS - 1).collect();
        s.push('…');
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn answer(id: &str, request: &str, model: &str, input: u64, write: u64, read: u64, output: u64) -> String {
        json!({"type": "assistant", "requestId": request, "timestamp": "2026-11-02T10:00:05Z",
               "message": {"id": id, "model": model, "content": [{"type": "text", "text": "ok"}],
               "usage": {"input_tokens": input, "cache_creation_input_tokens": write,
                         "cache_read_input_tokens": read, "output_tokens": output}}})
        .to_string()
    }

    fn user(content: serde_json::Value, at: &str) -> String {
        json!({"type": "user", "sessionId": "s1", "cwd": "/p", "gitBranch": "main", "version": "2.5.0",
               "timestamp": at, "message": {"role": "user", "content": content}})
        .to_string()
    }

    fn read(lines: &[String]) -> Transcript {
        let mut t = Transcript::default();
        for l in lines {
            t.feed(l);
        }
        t
    }

    #[test]
    fn each_answer_counts_once_also_when_it_has_several_lines() {
        let t = read(&[
            answer("m1", "r1", "opus", 3, 100, 0, 10),
            answer("m1", "r1", "opus", 3, 100, 0, 10),
            answer("m2", "r2", "opus", 1, 20, 100, 30),
            answer("m3", "r3", "haiku", 5, 0, 50, 7),
            answer("e1", "", "<synthetic>", 9, 9, 9, 9),
            "not json".into(),
        ]);
        assert_eq!(t.usage["opus"], Usage { input_tokens: 4, cache_write_tokens: 120, cache_read_tokens: 100, output_tokens: 40, requests: 2, ..Usage::default() });
        assert_eq!(t.usage["haiku"].requests, 1);
        assert_eq!(t.total().total(), 4 + 120 + 100 + 40 + 5 + 50 + 7);
        assert!(!t.usage.contains_key("<synthetic>"));
    }

    #[test]
    fn the_newest_line_of_an_answer_wins() {
        let t = read(&[answer("m1", "r1", "opus", 3, 100, 0, 10), answer("m1", "r1", "opus", 3, 100, 0, 12)]);
        assert_eq!(t.usage["opus"].output_tokens, 12);
        assert_eq!(t.usage["opus"].requests, 1);
    }

    #[test]
    fn a_saved_state_continues_without_counting_an_answer_twice() {
        let lines = [answer("m1", "r1", "opus", 3, 100, 0, 10), answer("m1", "r1", "opus", 3, 100, 0, 10), answer("m2", "r2", "opus", 1, 0, 0, 1)];
        let whole = read(&lines);
        // The file was read when it ended after the first line of m1.
        let mut part = read(&lines[..1]);
        part = serde_json::from_str(&serde_json::to_string(&part).unwrap()).unwrap();
        for l in &lines[1..] {
            part.feed(l);
        }
        assert_eq!(part, whole);
        assert_eq!(whole.total().requests, 2);
    }

    #[test]
    fn cost_and_hours_count_each_answer_once_in_the_hour_of_its_first_line() {
        let line = |at: &str, id: &str, out: u64| {
            json!({"type": "assistant", "requestId": id, "timestamp": at,
                   "message": {"id": id, "model": "claude-opus-5-5",
                   "usage": {"input_tokens": 0, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 0, "output_tokens": out,
                             "cache_creation": {"ephemeral_1h_input_tokens": 1000, "ephemeral_5m_input_tokens": 0}}}})
            .to_string()
        };
        let t = read(&[
            line("2026-11-02T10:59:59Z", "a", 100),
            // The same answer's next line, written in the next hour.
            line("2026-11-02T11:00:01Z", "a", 100),
            line("2026-11-02T11:30:00Z", "b", 50),
        ]);
        // 1000 × $8 (1-hour write) + 100 × $20 = 10,000 µ$; + 1000 × 8 + 50 × 20 = 9,000 µ$.
        assert_eq!(t.cost_micros, 19_000);
        let h10 = "2026-11-02T10:00:00Z".parse::<DateTime<Utc>>().unwrap().timestamp() / 3600;
        assert_eq!(t.hours.keys().copied().collect::<Vec<_>>(), [h10, h10 + 1]);
        assert_eq!((t.hours[&h10].cost_micros, t.hours[&h10].usage.requests, t.hours[&h10].usage.cache_write_1h_tokens), (10_000, 1, 1000));
        assert_eq!((t.hours[&(h10 + 1)].cost_micros, t.hours[&(h10 + 1)].usage.requests), (9_000, 1));
    }

    #[test]
    fn prompts_titles_and_times() {
        let t = read(&[
            json!({"type": "permission-mode", "permissionMode": "auto", "sessionId": "s1"}).to_string(),
            user(json!("<command-message>init</command-message>\n<command-name>/init</command-name>\n<command-args>a tool</command-args>"), "2026-11-02T10:00:00Z"),
            json!({"type": "user", "isMeta": true, "timestamp": "2026-11-02T09:59:00Z", "message": {"content": "meta"}}).to_string(),
            user(json!([{"type": "tool_result", "content": "x"}]), "2026-11-02T10:01:00Z"),
            user(json!("<local-command-stdout>done</local-command-stdout>"), "2026-11-02T10:02:00Z"),
            user(json!([{"type": "text", "text": "fix   the\nbug"}]), "2026-11-02T10:03:00Z"),
            json!({"type": "ai-title", "aiTitle": "First title", "sessionId": "s1"}).to_string(),
            json!({"type": "ai-title", "aiTitle": "Better title", "sessionId": "s1"}).to_string(),
            json!({"type": "relocated", "relocatedCwd": "/q"}).to_string(),
        ]);
        assert_eq!(t.session_id.as_deref(), Some("s1"));
        assert_eq!(t.cwd.as_deref(), Some("/q"));
        assert_eq!((t.git_branch.as_deref(), t.version.as_deref()), (Some("main"), Some("2.5.0")));
        assert_eq!(t.first_prompt.as_deref(), Some("/init a tool"));
        assert_eq!(t.last_prompt.as_deref(), Some("fix the bug"));
        assert_eq!(t.prompts, 2);
        assert_eq!(t.ai_title.as_deref(), Some("Better title"));
        // The meta record is older and still counts for the start time.
        assert_eq!(t.started_at.unwrap().to_rfc3339(), "2026-11-02T09:59:00+00:00");
        assert_eq!(t.updated_at.unwrap().to_rfc3339(), "2026-11-02T10:03:00+00:00");
    }

    #[test]
    fn long_prompts_are_clipped() {
        let long = "word ".repeat(200);
        let p = prompt_text(&serde_json::to_string(&long).unwrap()).unwrap();
        assert_eq!(p.chars().count(), PROMPT_CHARS);
        assert!(p.ends_with('…'));
        assert_eq!(prompt_text(r#""<bash-input>ls -la</bash-input>""#).as_deref(), Some("! ls -la"));
        assert_eq!(prompt_text(r#""[Request interrupted by user]""#), None);
    }
}
