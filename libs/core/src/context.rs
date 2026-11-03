//! The anatomy of a lane's context: what fills the context window at each
//! model call.
//!
//! The size is exact: a call's input tokens (new + cache write + cache
//! read). The split is estimated from how the size grows between calls:
//!
//! 1. The first call is `Start`: system prompt, tool definitions,
//!    instructions (CLAUDE.md, reminders) and the first prompt.
//! 2. From one call to the next, the context grows by what came between
//!    them. Up to the previous answer's output tokens goes to
//!    `Claude output` (its text, thinking and tool call inputs). The rest
//!    goes to the prompts and tool results that arrived between the two
//!    calls, split by their size in bytes.
//! 3. When the context shrinks (thinking cleared, context edits), every
//!    part shrinks in proportion.
//! 4. After a compaction, the context is `Start` plus `Compacted summary`.
//!
//! Claude Code also writes `api-request` records with the request's
//! message hashes, but most messages have no stored blob, so the request
//! cannot be rebuilt from them.

use crate::anatomy::{ContextPart, ContextPoint, EventKind, Lane};

pub const START: &str = "Start";
pub const OUTPUT: &str = "Claude output";
pub const PROMPTS: &str = "Prompts";
pub const SUMMARY: &str = "Compacted summary";
pub const OTHER: &str = "Other";

pub fn tool_part(tool: &str) -> String {
    format!("Tool: {tool}")
}

/// Fills `lane.context`, and `context_tokens` / `added_tokens` of its events.
pub fn analyze(lane: &mut Lane) {
    let mut parts: Vec<(String, u64)> = Vec::new();
    let mut prev: Option<(u64, u64)> = None;
    let mut start_tokens = 0;
    let mut pending: Vec<usize> = Vec::new();
    let mut compacted: Option<usize> = None;
    let mut points = Vec::new();
    for i in 0..lane.events.len() {
        match lane.events[i].kind {
            EventKind::Prompt | EventKind::Tool => pending.push(i),
            EventKind::Compact => compacted = Some(i),
            EventKind::Error => {}
            EventKind::Answer => {
                let Some(u) = lane.events[i].usage else { continue };
                let total = u.input_total();
                match (prev, compacted) {
                    (None, _) => {
                        parts = vec![(START.into(), total)];
                        start_tokens = total;
                    }
                    (Some(_), Some(k)) => {
                        let start = start_tokens.min(total);
                        parts = vec![(START.into(), start), (SUMMARY.into(), total - start)];
                        lane.events[k].added_tokens = Some(total - start);
                    }
                    (Some((before, output)), None) if total >= before => {
                        let grew = total - before;
                        let from_output = output.min(grew);
                        add(&mut parts, OUTPUT, from_output);
                        let rest = grew - from_output;
                        let weights: Vec<(usize, String, u64)> = pending
                            .iter()
                            .map(|&p| {
                                let e = &lane.events[p];
                                match e.kind {
                                    EventKind::Tool => (p, tool_part(e.tool.as_deref().unwrap_or("tool")), e.result_bytes.unwrap_or(0)),
                                    _ => (p, PROMPTS.to_string(), e.text.as_ref().map_or(0, |t| t.len() as u64)),
                                }
                            })
                            .collect();
                        let shares = split(rest, &weights.iter().map(|w| w.2).collect::<Vec<_>>());
                        match shares {
                            Some(shares) => {
                                for ((p, name, _), n) in weights.into_iter().zip(shares) {
                                    add(&mut parts, &name, n);
                                    lane.events[p].added_tokens = Some(n);
                                }
                            }
                            None => add(&mut parts, OTHER, rest),
                        }
                    }
                    (Some(_), None) => scale(&mut parts, total),
                }
                parts.retain(|(_, n)| *n > 0);
                points.push(ContextPoint {
                    at: lane.events[i].end,
                    event: i,
                    total,
                    parts: parts.iter().map(|(name, tokens)| ContextPart { name: name.clone(), tokens: *tokens }).collect(),
                });
                lane.events[i].context_tokens = Some(total);
                prev = Some((total, u.output_tokens));
                pending.clear();
                compacted = None;
            }
        }
    }
    lane.context = points;
}

fn add(parts: &mut Vec<(String, u64)>, name: &str, n: u64) {
    if n == 0 {
        return;
    }
    match parts.iter_mut().find(|(p, _)| p == name) {
        Some((_, v)) => *v += n,
        None => parts.push((name.to_string(), n)),
    }
}

/// `n` split in proportion to `weights`, adding up to exactly `n`; equal
/// shares when every weight is 0; None when there is nothing to split into.
fn split(n: u64, weights: &[u64]) -> Option<Vec<u64>> {
    if weights.is_empty() {
        return None;
    }
    let sum: u64 = weights.iter().sum();
    let weights: Vec<u64> = if sum == 0 { vec![1; weights.len()] } else { weights.to_vec() };
    let sum: u128 = weights.iter().map(|w| *w as u128).sum();
    let mut out: Vec<u64> = weights.iter().map(|w| (n as u128 * *w as u128 / sum) as u64).collect();
    let short = n - out.iter().sum::<u64>();
    // The rounding rest goes to the largest weight; the first of equal ones.
    // (`max_by_key` returns the last of equal ones, so search backwards.)
    let biggest = (0..weights.len()).rev().max_by_key(|&i| weights[i]).unwrap();
    out[biggest] += short;
    Some(out)
}

/// Every part shrunk in proportion, so they add up to `total`.
fn scale(parts: &mut [(String, u64)], total: u64) {
    let weights: Vec<u64> = parts.iter().map(|(_, n)| *n).collect();
    if let Some(shares) = split(total, &weights) {
        for (p, n) in parts.iter_mut().zip(shares) {
            p.1 = n;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::anatomy::LaneReader;
    use serde_json::json;

    fn answer(t: &str, id: &str, context: u64, out: u64, tools: serde_json::Value) -> String {
        json!({"type": "assistant", "requestId": id, "timestamp": format!("2026-11-02T10:00:{t}Z"),
               "message": {"id": id, "model": "m", "content": tools,
                           "usage": {"input_tokens": 1, "cache_creation_input_tokens": 9, "cache_read_input_tokens": context - 10, "output_tokens": out}}})
        .to_string()
    }

    fn result(t: &str, id: &str, bytes: usize) -> String {
        json!({"type": "user", "timestamp": format!("2026-11-02T10:00:{t}Z"),
               "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "x".repeat(bytes)}]}})
        .to_string()
    }

    fn parts(p: &ContextPoint) -> Vec<(&str, u64)> {
        p.parts.iter().map(|x| (x.name.as_str(), x.tokens)).collect()
    }

    #[test]
    fn growth_goes_to_claude_output_then_to_the_tool_results_by_size() {
        let mut r = LaneReader::main();
        for line in [
            json!({"type": "user", "timestamp": "2026-11-02T10:00:00Z", "message": {"content": "read both files"}}).to_string(),
            answer("01", "a1", 20_000, 100, json!([
                {"type": "tool_use", "id": "r1", "name": "Read", "input": {"file_path": "/big"}},
                {"type": "tool_use", "id": "r2", "name": "Bash", "input": {"command": "ls"}}])),
            result("02", "r1", 3000),
            result("03", "r2", 1000),
            // +4100: 100 from the answer, 4000 from the results (3:1).
            answer("04", "a2", 24_100, 50, json!([])),
            json!({"type": "user", "timestamp": "2026-11-02T10:00:05Z", "message": {"content": "thanks"}}).to_string(),
            // +550: 50 from the answer, 500 from the prompt.
            answer("06", "a3", 24_650, 10, json!([])),
            // Thinking cleared: the context shrinks to 12_325, every part halves.
            answer("07", "a4", 12_325, 10, json!([])),
            json!({"type": "system", "subtype": "compact_boundary", "timestamp": "2026-11-02T10:00:08Z",
                   "compactMetadata": {"trigger": "manual", "preTokens": 12325, "postTokens": 3000}}).to_string(),
            answer("09", "a5", 23_000, 10, json!([])),
        ] {
            r.feed(&line);
        }
        let lane = r.finish();
        let c = &lane.context;
        assert_eq!(c.len(), 5);
        assert_eq!(parts(&c[0]), [("Start", 20_000)]);
        assert_eq!(parts(&c[1]), [("Start", 20_000), ("Claude output", 100), ("Tool: Read", 3000), ("Tool: Bash", 1000)]);
        assert_eq!(parts(&c[2]), [("Start", 20_000), ("Claude output", 150), ("Tool: Read", 3000), ("Tool: Bash", 1000), ("Prompts", 500)]);
        assert_eq!(parts(&c[3]), [("Start", 10_000), ("Claude output", 75), ("Tool: Read", 1500), ("Tool: Bash", 500), ("Prompts", 250)]);
        assert_eq!(parts(&c[4]), [("Start", 20_000), ("Compacted summary", 3000)]);
        for p in c {
            assert_eq!(p.parts.iter().map(|x| x.tokens).sum::<u64>(), p.total);
        }
        let read = lane.events.iter().find(|e| e.tool.as_deref() == Some("Read")).unwrap();
        assert_eq!(read.added_tokens, Some(3000));
        assert_eq!(lane.events[1].context_tokens, Some(20_000));
    }

    #[test]
    fn split_adds_up_exactly() {
        assert_eq!(split(10, &[1, 1, 1]), Some(vec![4, 3, 3]));
        assert_eq!(split(7, &[0, 0]), Some(vec![4, 3]));
        assert_eq!(split(5, &[]), None);
        assert_eq!(split(0, &[5, 5]), Some(vec![0, 0]));
    }
}
