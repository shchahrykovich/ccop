//! One session as `ccop sessions --json` prints it: the main transcript and
//! its subagents together. The Swift app decodes this JSON
//! (`apps/menubar/Sources/CCOPKit/Session.swift`); `api/sessions.example.json`
//! is checked by tests on both sides.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::transcript::Transcript;
use crate::usage::Usage;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    /// The folder the session ran in. From the transcript, or else from the
    /// name of its folder in `~/.claude/projects`.
    pub project_dir: String,
    /// The user's name for the session, Claude Code's title, or the first prompt.
    pub title: String,
    pub first_prompt: Option<String>,
    pub last_prompt: Option<String>,
    pub git_branch: Option<String>,
    pub version: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
    /// The newest record of the session or its subagents.
    pub updated_at: Option<DateTime<Utc>>,
    /// When a file of the session last changed.
    pub modified_at: DateTime<Utc>,
    /// A file of the session changed in the last few minutes.
    pub active: bool,
    pub prompts: u64,
    pub subagents: u64,
    /// All tokens: the main transcript and the subagents.
    pub usage: Usage,
    /// The part of `usage` that the subagents used.
    pub subagent_usage: Usage,
    /// API-equivalent cost of all calls, subagents too, in millionths of a dollar.
    pub cost_micros: u64,
    /// All tokens by model, the most used first.
    pub models: Vec<ModelUsage>,
    pub transcript: String,
    /// Bytes of the main transcript and the subagents' files.
    pub size_bytes: u64,
    pub continued_in: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelUsage {
    pub model: String,
    pub usage: Usage,
}

/// A transcript file and what is known about it on disk.
pub struct FileFacts<'a> {
    pub path: &'a str,
    pub transcript: &'a Transcript,
    pub size: u64,
    pub modified_at: DateTime<Utc>,
}

impl Session {
    /// `id` is the file name of the main transcript without `.jsonl`;
    /// `folder` is its folder's name in `~/.claude/projects`.
    pub fn build(id: &str, folder: &str, main: &FileFacts, subagents: &[FileFacts], now: DateTime<Utc>, active_secs: i64) -> Session {
        let t = main.transcript;
        let mut models: BTreeMap<String, Usage> = BTreeMap::new();
        let mut subagent_usage = Usage::default();
        let mut add = |tr: &Transcript, sub: bool| {
            for (model, u) in &tr.usage {
                *models.entry(model.clone()).or_default() += *u;
                if sub {
                    subagent_usage += *u;
                }
            }
        };
        add(t, false);
        let mut cost_micros = t.cost_micros;
        let mut updated_at = t.updated_at;
        let mut modified_at = main.modified_at;
        let mut size = main.size;
        for s in subagents {
            add(s.transcript, true);
            cost_micros += s.transcript.cost_micros;
            updated_at = updated_at.max(s.transcript.updated_at);
            modified_at = modified_at.max(s.modified_at);
            size += s.size;
        }
        let mut usage = Usage::default();
        for u in models.values() {
            usage += *u;
        }
        let mut models: Vec<ModelUsage> = models
            .into_iter()
            .filter(|(_, u)| u.total() > 0 || u.requests > 0)
            .map(|(model, usage)| ModelUsage { model: if model.is_empty() { "unknown".into() } else { model }, usage })
            .collect();
        models.sort_by(|a, b| b.usage.total().cmp(&a.usage.total()).then(a.model.cmp(&b.model)));
        let title = t
            .agent_name
            .clone()
            .or_else(|| t.ai_title.clone())
            .or_else(|| t.first_prompt.clone())
            .unwrap_or_else(|| "(no prompt)".into());
        Session {
            id: id.to_string(),
            project_dir: t.cwd.clone().unwrap_or_else(|| folder.to_string()),
            title,
            first_prompt: t.first_prompt.clone(),
            last_prompt: t.last_prompt.clone(),
            git_branch: t.git_branch.clone(),
            version: t.version.clone(),
            started_at: t.started_at,
            updated_at,
            modified_at,
            active: (now - modified_at).num_seconds() < active_secs,
            prompts: t.prompts,
            subagents: subagents.len() as u64,
            usage,
            subagent_usage,
            cost_micros,
            models,
            transcript: main.path.to_string(),
            size_bytes: size,
            continued_in: t.continued_in.clone(),
        }
    }

    /// The last folder name of the project: `shop` for `/Users/me/code/shop`.
    pub fn project_name(&self) -> &str {
        self.project_dir.trim_end_matches('/').rsplit('/').next().unwrap_or(&self.project_dir)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn transcript(lines: &[serde_json::Value]) -> Transcript {
        let mut t = Transcript::default();
        for l in lines {
            t.feed(&l.to_string());
        }
        t
    }

    fn answer(id: &str, model: &str, out: u64, at: &str) -> serde_json::Value {
        json!({"type": "assistant", "requestId": id, "timestamp": at,
               "message": {"id": id, "model": model, "usage": {"input_tokens": 1, "output_tokens": out}}})
    }

    #[test]
    fn a_session_adds_its_subagents() {
        let at = |s: &str| s.parse::<DateTime<Utc>>().unwrap();
        let main = transcript(&[
            json!({"type": "user", "cwd": "/Users/me/ccop", "timestamp": "2026-11-02T10:00:00Z", "message": {"content": "hello"}}),
            answer("a", "opus", 10, "2026-11-02T10:00:05Z"),
        ]);
        let sub = transcript(&[answer("b", "haiku", 100, "2026-11-02T10:07:00Z")]);
        let s = Session::build(
            "s1",
            "-Users-me-ccop",
            &FileFacts { path: "/x/s1.jsonl", transcript: &main, size: 10, modified_at: at("2026-11-02T10:00:06Z") },
            &[FileFacts { path: "/x/s1/subagents/agent-1.jsonl", transcript: &sub, size: 5, modified_at: at("2026-11-02T10:07:01Z") }],
            at("2026-11-02T10:08:00Z"),
            120,
        );
        assert_eq!((s.title.as_str(), s.project_name()), ("hello", "ccop"));
        assert_eq!((s.usage.output_tokens, s.usage.requests, s.subagent_usage.output_tokens), (110, 2, 100));
        assert_eq!(s.models.iter().map(|m| m.model.as_str()).collect::<Vec<_>>(), ["haiku", "opus"]);
        assert_eq!(s.updated_at, Some(at("2026-11-02T10:07:00Z")));
        assert_eq!((s.size_bytes, s.subagents, s.active), (15, 1, true));
    }

    #[test]
    fn without_a_cwd_the_folder_name_is_the_project() {
        let t = Transcript::default();
        let now = Utc::now();
        let s = Session::build("s2", "-Users-me-x", &FileFacts { path: "p", transcript: &t, size: 0, modified_at: now }, &[], now + chrono::Duration::hours(1), 120);
        assert_eq!((s.project_dir.as_str(), s.title.as_str(), s.active), ("-Users-me-x", "(no prompt)", false));
    }
}
