//! Where the clock time of one session went: `ccop time`.
//!
//! The clock is split so the parts add up to the session's length. Each
//! moment goes to the first of these that is true:
//! 1. the main lane waits for a model call;
//! 2. the main lane waits for a tool (not `Agent`);
//! 3. a subagent is running, and the main lane does nothing;
//! 4. nothing runs: the session waits for a person.
//!
//! Model time is from the request to the last line of the answer, so it
//! includes API retries and waits for a rate limit. The transcript cannot
//! tell them apart. In subagents the times overlap, so `work` adds up to more
//! than the clock.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::anatomy::{Anatomy, Event, EventKind};

/// How many of the slowest calls and turns are kept.
pub const SLOWEST: usize = 10;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Timing {
    pub session_id: String,
    /// From the first to the last record of the session. The sum of the next four.
    pub wall_ms: u64,
    pub model_ms: u64,
    pub tools_ms: u64,
    pub subagents_ms: u64,
    pub waiting_ms: u64,
    /// All lanes added up: parallel work counts more than once.
    pub work: Work,
    /// The most time first, all lanes.
    pub tools: Vec<ToolTime>,
    /// The longest model and tool calls, the longest first.
    pub slowest: Vec<SlowCall>,
    /// The longest turns, the longest first.
    pub turns: Vec<SlowTurn>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Work {
    pub model_calls: u64,
    pub model_ms: u64,
    pub tool_calls: u64,
    pub tool_ms: u64,
    pub subagents: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ToolTime {
    pub tool: String,
    pub calls: u64,
    /// Time with at least one such call running, per lane, added up. Calls
    /// sent together overlap, and count once here.
    pub clock_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SlowCall {
    /// `model`, or the tool's name.
    pub name: String,
    pub lane: String,
    pub lane_name: String,
    pub event: usize,
    /// For `ccop call`.
    pub tool_use_id: Option<String>,
    pub ms: u64,
    /// A model call: what it wrote. A slow call that wrote little was waiting.
    pub output_tokens: Option<u64>,
    pub text: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SlowTurn {
    pub index: u64,
    pub ms: u64,
    pub prompt: String,
    pub tool_calls: u64,
    pub subagents: usize,
}

fn ms(e: &Event) -> u64 {
    (e.end - e.start).num_milliseconds().max(0) as u64
}

const MODEL: usize = 0;
const TOOL: usize = 1;
const SUBAGENT: usize = 2;

/// Each moment from `start` to `end` goes to the first class that is active;
/// the last slot is the time when none is.
fn split(start: i64, end: i64, spans: &[(i64, i64, usize)]) -> [u64; 4] {
    let mut points: Vec<(i64, i32, usize)> = Vec::with_capacity(spans.len() * 2);
    for &(s, e, class) in spans {
        points.push((s.clamp(start, end), 1, class));
        points.push((e.clamp(start, end), -1, class));
    }
    points.sort_by_key(|p| p.0);
    let mut parts = [0u64; 4];
    let mut active = [0i32; 3];
    let mut at = start;
    for (t, delta, class) in points {
        let slot = active.iter().position(|n| *n > 0).unwrap_or(3);
        parts[slot] += (t - at).max(0) as u64;
        at = t;
        active[class] += delta;
    }
    parts[3] += (end - at).max(0) as u64;
    parts
}

fn millis(t: DateTime<Utc>) -> i64 {
    t.timestamp_millis()
}

/// The time that at least one of these events is running. Events of one
/// lane only: this is how long that lane waited for them.
pub fn clock_ms<'a>(events: impl Iterator<Item = &'a Event>) -> u64 {
    let mut spans: Vec<(i64, i64)> = events.map(|e| (millis(e.start), millis(e.end))).collect();
    spans.sort();
    let mut total = 0;
    let mut covered = i64::MIN;
    for (start, end) in spans {
        let from = start.max(covered);
        if end > from {
            total += (end - from) as u64;
            covered = end;
        }
    }
    total
}

/// `clock_ms` for each name: per lane, then added up.
pub fn clock_by_name<'a>(a: &'a Anatomy, name: impl Fn(&'a Event) -> Option<&'a str>) -> BTreeMap<&'a str, u64> {
    let mut out: BTreeMap<&str, u64> = BTreeMap::new();
    for lane in &a.lanes {
        let mut by_name: BTreeMap<&str, Vec<&Event>> = BTreeMap::new();
        for e in lane.events.iter().filter(|e| e.kind == EventKind::Tool) {
            if let Some(n) = name(e) {
                by_name.entry(n).or_default().push(e);
            }
        }
        for (n, events) in by_name {
            *out.entry(n).or_default() += clock_ms(events.into_iter());
        }
    }
    out
}

/// A tool's name as the causes and this report give it.
pub fn tool_name(e: &Event) -> &str {
    e.tool.as_deref().filter(|t| !t.is_empty()).unwrap_or("Tool")
}

pub fn analyze(a: &Anatomy) -> Timing {
    let (start, end) = (a.started_at.map_or(0, millis), a.ended_at.map_or(0, millis));
    let mut spans: Vec<(i64, i64, usize)> = Vec::new();
    let mut work = Work::default();
    let mut slowest: Vec<SlowCall> = Vec::new();
    for (i, lane) in a.lanes.iter().enumerate() {
        if i > 0 {
            work.subagents += 1;
            if let (Some(s), Some(e)) = (lane.started_at, lane.ended_at) {
                spans.push((millis(s), millis(e), SUBAGENT));
            }
        }
        for (ei, e) in lane.events.iter().enumerate() {
            let is_model = e.kind == EventKind::Answer && e.usage.is_some();
            if !is_model && e.kind != EventKind::Tool {
                continue;
            }
            if is_model {
                work.model_calls += 1;
                work.model_ms += ms(e);
            } else {
                work.tool_calls += 1;
                work.tool_ms += ms(e);
            }
            if i == 0 {
                // A foreground `Agent` call waits for its subagent, whose time is the subagent's.
                let class = if is_model {
                    MODEL
                } else if e.tool.as_deref() == Some("Agent") {
                    SUBAGENT
                } else {
                    TOOL
                };
                spans.push((millis(e.start), millis(e.end), class));
            }
            slowest.push(SlowCall {
                name: if is_model { "model".into() } else { e.tool.clone().unwrap_or_else(|| "Tool".into()) },
                lane: lane.id.clone(),
                lane_name: lane.name.clone(),
                event: ei,
                tool_use_id: e.tool_use_id.clone(),
                ms: ms(e),
                output_tokens: e.usage.filter(|_| is_model).map(|u| u.output_tokens),
                text: e.text.clone(),
            });
        }
    }
    slowest.sort_by_key(|c| std::cmp::Reverse(c.ms));
    slowest.truncate(SLOWEST);
    let clocks = clock_by_name(a, |e| Some(tool_name(e)));
    let mut tools: Vec<ToolTime> = a
        .tools
        .iter()
        .map(|t| {
            let tool = if t.tool.is_empty() { "Tool" } else { t.tool.as_str() };
            ToolTime { tool: tool.to_string(), calls: t.calls, clock_ms: clocks.get(tool).copied().unwrap_or(0) }
        })
        .collect();
    tools.sort_by(|a, b| b.clock_ms.cmp(&a.clock_ms).then(a.tool.cmp(&b.tool)));
    let mut turns: Vec<SlowTurn> = a
        .turns
        .iter()
        .map(|t| SlowTurn {
            index: t.index,
            ms: (t.end - t.start).num_milliseconds().max(0) as u64,
            prompt: t.prompt.clone(),
            tool_calls: t.tool_calls,
            subagents: t.subagents.len(),
        })
        .collect();
    turns.sort_by_key(|t| std::cmp::Reverse(t.ms));
    turns.truncate(SLOWEST);
    let [model_ms, tools_ms, subagents_ms, waiting_ms] = split(start, end, &spans);
    Timing { session_id: a.session_id.clone(), wall_ms: (end - start).max(0) as u64, model_ms, tools_ms, subagents_ms, waiting_ms, work, tools, slowest, turns }
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

    fn answer(t: &str, id: &str, out: u64, blocks: Value) -> Value {
        json!({"type": "assistant", "requestId": format!("r{id}"), "timestamp": at(t),
               "message": {"id": id, "model": "claude-opus-5-5", "content": blocks,
                           "usage": {"input_tokens": 1, "output_tokens": out}}})
    }

    fn tool(id: &str, name: &str) -> Value {
        json!({"type": "tool_use", "id": id, "name": name, "input": {"command": "ls", "description": "List"}})
    }

    fn result(t: &str, id: &str) -> Value {
        json!({"type": "user", "timestamp": at(t), "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "ok"}]}})
    }

    #[test]
    fn the_parts_add_up_to_the_clock_and_a_person_is_waiting_time() {
        let main = lane(
            LaneReader::main(),
            &[
                prompt("00:00", "go"),
                answer("00:10", "m1", 5, json!([tool("t1", "Bash")])), // model 10 s
                result("00:40", "t1"),                                 // tool 30 s
                answer("00:45", "m2", 5, json!([])),                   // model 5 s
                prompt("10:45", "more"),                               // a person: 10 min
                answer("10:50", "m3", 5, json!([])),                   // model 5 s
            ],
        );
        let t = analyze(&build("s", main, vec![]));
        assert_eq!(t.wall_ms, 650_000);
        assert_eq!((t.model_ms, t.tools_ms, t.subagents_ms, t.waiting_ms), (20_000, 30_000, 0, 600_000));
        assert_eq!(t.model_ms + t.tools_ms + t.subagents_ms + t.waiting_ms, t.wall_ms);
        assert_eq!((t.work.model_calls, t.work.model_ms, t.work.tool_calls, t.work.tool_ms), (3, 20_000, 1, 30_000));
        assert_eq!(t.slowest[0].name, "Bash");
        assert_eq!(t.slowest[0].ms, 30_000);
        assert_eq!(t.slowest[0].tool_use_id.as_deref(), Some("t1"));
        assert_eq!(t.tools[0].clock_ms, 30_000);
        assert_eq!(t.turns[0].index, 1);
    }

    /// The main lane waits for a background subagent, and its hand-back is a
    /// meta record: that wait is subagent time, not model time.
    #[test]
    fn waiting_for_a_background_subagent_is_not_model_time() {
        let main = lane(
            LaneReader::main(),
            &[
                prompt("00:00", "go"),
                answer("00:10", "m1", 5, json!([tool("t1", "Agent")])),
                result("00:11", "t1"),
                answer("00:15", "m2", 5, json!([])),
                json!({"type": "user", "isMeta": true, "timestamp": at("20:00"), "message": {"content": "[Subagent hand-back] done"}}),
                answer("20:05", "m3", 3854, json!([])),
            ],
        );
        let sub = lane(
            LaneReader::subagent("a1", LaneMeta { tool_use_id: Some("t1".into()), ..LaneMeta::default() }),
            &[
                json!({"type": "user", "isSidechain": true, "timestamp": at("00:11"), "message": {"content": "work"}}),
                answer("20:00", "s1", 5, json!([])),
            ],
        );
        let t = analyze(&build("s", main, vec![sub]));
        assert_eq!(t.model_ms, 19_000, "10 s + 4 s + 5 s of the main lane");
        assert_eq!(t.subagents_ms, 1_186_000);
        assert_eq!(t.waiting_ms, 0);
        assert_eq!(t.model_ms + t.tools_ms + t.subagents_ms + t.waiting_ms, t.wall_ms);
        assert_eq!(t.work.subagents, 1);
        // The subagent's own call is the slowest; the main lane's last call took 5 s.
        assert_eq!(t.slowest[0].lane, "a1");
        assert_eq!(t.slowest.iter().find(|c| c.output_tokens == Some(3854)).unwrap().ms, 5_000);
    }

    #[test]
    fn overlapping_tools_count_once_on_the_clock_and_twice_as_work() {
        let main = lane(
            LaneReader::main(),
            &[
                prompt("00:00", "go"),
                answer("00:00", "m1", 5, json!([tool("t1", "Bash"), tool("t2", "Read")])),
                result("00:10", "t1"),
                result("00:30", "t2"),
            ],
        );
        let t = analyze(&build("s", main, vec![]));
        assert_eq!(t.tools_ms, 30_000);
        assert_eq!(t.work.tool_ms, 40_000);
        // Bash from 0 to 10 s, Read from 0 to 30 s: each on its own clock.
        assert_eq!(t.tools.iter().map(|x| (x.tool.as_str(), x.clock_ms)).collect::<Vec<_>>(), [("Read", 30_000), ("Bash", 10_000)]);
    }

    /// Twenty edits sent together that each end 3 minutes later are 3 minutes, not an hour.
    #[test]
    fn calls_of_one_tool_sent_together_count_once() {
        let blocks: Vec<Value> = (0..20).map(|i| tool(&format!("t{i}"), "Edit")).collect();
        let mut lines = vec![prompt("00:00", "go"), answer("00:00", "m1", 5, json!(blocks))];
        lines.extend((0..20).map(|i| result("03:00", &format!("t{i}"))));
        let t = analyze(&build("s", lane(LaneReader::main(), &lines), vec![]));
        assert_eq!(t.tools[0].clock_ms, 180_000);
        assert_eq!(t.work.tool_ms, 3_600_000);
    }

    #[test]
    fn an_empty_session_has_no_time() {
        let t = analyze(&build("s", lane(LaneReader::main(), &[]), vec![]));
        assert_eq!(t.wall_ms, 0);
        assert!(t.slowest.is_empty() && t.turns.is_empty());
    }
}
