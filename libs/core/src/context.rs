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

use serde::Serialize;

use crate::anatomy::{ContextItem, ContextPart, ContextPoint, EventKind, Lane};

pub const START: &str = "Start";
pub const OUTPUT: &str = "Claude output";
pub const PROMPTS: &str = "Prompts";
pub const SUMMARY: &str = "Compacted summary";
pub const REPORTS: &str = "Subagent reports";
pub const OTHER: &str = "Other";

pub fn tool_part(tool: &str) -> String {
    format!("Tool: {tool}")
}

/// One thing in the context while the walk runs: what put it there, its
/// part, its tokens, and the first call that read it.
struct Live {
    event: Option<usize>,
    part: String,
    tokens: u64,
    first: usize,
}

/// Fills `lane.context` and `lane.context_items`, and `context_tokens` /
/// `added_tokens` of its events.
///
/// Each prompt, tool result and answer is an item. A call's parts are the
/// sums of the items in its context by part, so the items of a call add up
/// to its parts and to its size. When the context shrinks, every item
/// shrinks in proportion: the item ends at the call before, and goes on
/// with fewer tokens from that call.
pub fn analyze(lane: &mut Lane) {
    let mut live: Vec<Live> = Vec::new();
    let mut items: Vec<ContextItem> = Vec::new();
    let mut prev: Option<(u64, u64, usize)> = None;
    let mut start_tokens = 0;
    let mut pending: Vec<usize> = Vec::new();
    let mut compacted: Option<usize> = None;
    let mut points = Vec::new();
    let end = |live: &mut Vec<Live>, items: &mut Vec<ContextItem>, last: usize| {
        items.extend(live.drain(..).map(|l| ContextItem { event: l.event, part: l.part, first_call: l.first, last_call: last, tokens: l.tokens }));
    };
    for i in 0..lane.events.len() {
        match lane.events[i].kind {
            EventKind::Prompt | EventKind::Tool | EventKind::Report => pending.push(i),
            EventKind::Compact => compacted = Some(i),
            EventKind::Error => {}
            EventKind::Answer => {
                let Some(u) = lane.events[i].usage else { continue };
                let total = u.input_total();
                let call = points.len();
                let new = |event: Option<usize>, part: &str, tokens: u64| Live { event, part: part.to_string(), tokens, first: call };
                match (prev, compacted) {
                    (None, _) => {
                        live.push(new(None, START, total));
                        start_tokens = total;
                    }
                    (Some(_), Some(k)) => {
                        end(&mut live, &mut items, call - 1);
                        let start = start_tokens.min(total);
                        live.push(new(None, START, start));
                        live.push(new(Some(k), SUMMARY, total - start));
                        lane.events[k].added_tokens = Some(total - start);
                    }
                    (Some((before, output, answer)), None) if total >= before => {
                        let grew = total - before;
                        let from_output = output.min(grew);
                        live.push(new(Some(answer), OUTPUT, from_output));
                        let rest = grew - from_output;
                        let weights: Vec<(usize, String, u64)> = pending
                            .iter()
                            .map(|&p| {
                                let e = &lane.events[p];
                                match e.kind {
                                    EventKind::Tool => (p, tool_part(e.tool.as_deref().unwrap_or("tool")), e.result_bytes.unwrap_or(0)),
                                    EventKind::Report => (p, REPORTS.to_string(), e.result_bytes.unwrap_or(0)),
                                    _ => (p, PROMPTS.to_string(), e.text.as_ref().map_or(0, |t| t.len() as u64)),
                                }
                            })
                            .collect();
                        let shares = split(rest, &weights.iter().map(|w| w.2).collect::<Vec<_>>());
                        match shares {
                            Some(shares) => {
                                for ((p, name, _), n) in weights.into_iter().zip(shares) {
                                    live.push(new(Some(p), &name, n));
                                    lane.events[p].added_tokens = Some(n);
                                }
                            }
                            None => live.push(new(None, OTHER, rest)),
                        }
                    }
                    (Some(_), None) => {
                        // Every item shrinks: it ends here and goes on smaller.
                        let shares = split(total, &live.iter().map(|l| l.tokens).collect::<Vec<_>>()).unwrap_or_default();
                        let old = std::mem::take(&mut live);
                        let mut done: Vec<Live> = Vec::new();
                        for (l, n) in old.into_iter().zip(shares) {
                            live.push(Live { event: l.event, part: l.part.clone(), tokens: n, first: call });
                            done.push(l);
                        }
                        end(&mut done, &mut items, call - 1);
                    }
                }
                live.retain(|l| l.tokens > 0);
                let mut parts: Vec<(String, u64)> = Vec::new();
                for l in &live {
                    add(&mut parts, &l.part, l.tokens);
                }
                points.push(ContextPoint {
                    at: lane.events[i].end,
                    event: i,
                    total,
                    parts: parts.into_iter().map(|(name, tokens)| ContextPart { name, tokens }).collect(),
                });
                lane.events[i].context_tokens = Some(total);
                prev = Some((total, u.output_tokens, i));
                pending.clear();
                compacted = None;
            }
        }
    }
    if let Some(last) = points.len().checked_sub(1) {
        end(&mut live, &mut items, last);
    }
    items.sort_by_key(|it| (it.first_call, it.last_call));
    lane.context = points;
    lane.context_items = items;
}

/// The items in the context of call `call` (an index into `lane.context`),
/// largest first.
pub fn items_at(lane: &Lane, call: usize) -> Vec<&ContextItem> {
    let mut out: Vec<&ContextItem> = lane.context_items.iter().filter(|it| it.first_call <= call && call <= it.last_call).collect();
    out.sort_by_key(|it| std::cmp::Reverse(it.tokens));
    out
}

/// What one call's context holds: `ccop context`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Contents {
    pub lane: String,
    /// 1 for the lane's first call.
    pub call: usize,
    pub calls: usize,
    /// Index into the lane's `events`: the answer of this call.
    pub event: usize,
    /// The call's context size. Exact; the rows' tokens are estimated.
    pub total: u64,
    /// Largest first. All of them add up to `total`.
    pub rows: Vec<ContentRow>,
}

/// One file, command, prompt or other thing in a context; with `each`, one
/// item.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ContentRow {
    pub part: String,
    /// The file, command, prompt or tool input; the part's name for `Start`,
    /// `Other` and Claude's answers together.
    pub label: String,
    pub tokens: u64,
    /// The events that put it there (indexes into the lane's `events`),
    /// largest first. Several when the same file was read again.
    pub events: Vec<usize>,
    /// The tool calls among them, in the same order.
    pub tool_use_ids: Vec<String>,
}

/// The rows of call `call` (an index into `lane.context`). Grouped: one row
/// per file, command or prompt, and one for all of Claude's answers. With
/// `each`: one row per item. A path in the project folder `dir` is shown
/// from that folder. A subagent's report is named by its lane in `lanes`
/// (the session's lanes): one row per subagent, grouped.
pub fn contents(lane: &Lane, call: usize, each: bool, dir: Option<&str>, lanes: &[Lane]) -> Option<Contents> {
    let point = lane.context.get(call)?;
    let mut rows: Vec<ContentRow> = Vec::new();
    for it in items_at(lane, call) {
        let event = it.event.and_then(|e| lane.events.get(e));
        let label = match event {
            Some(e) if e.kind == EventKind::Answer && !each => it.part.clone(),
            Some(e) if e.kind == EventKind::Report => {
                let from = e.agent_id.as_deref().unwrap_or("another agent");
                let name = lanes.iter().find(|l| l.id == from).map_or_else(|| format!("from {from}"), |l| l.name.clone());
                match (&e.text, each) {
                    (Some(t), true) => crate::anatomy::clip(&format!("{name}: {t}"), crate::anatomy::SUMMARY_CHARS),
                    _ => name,
                }
            }
            Some(e) => e
                .text
                .as_deref()
                .map(|t| {
                    let t = crate::anatomy::clip(dir.map_or(t, |d| in_folder(t, d)), crate::anatomy::SUMMARY_CHARS);
                    // Each addition: a part of a file says which part, so two reads of one file differ.
                    match e.lines.filter(|_| each) {
                        Some(l) => format!("{t} · {l}"),
                        None => t,
                    }
                })
                .unwrap_or_else(|| it.part.clone()),
            None => it.part.clone(),
        };
        let use_id = event.and_then(|e| e.tool_use_id.clone());
        let same = (!each).then(|| rows.iter_mut().find(|r| r.part == it.part && r.label == label)).flatten();
        match same {
            Some(r) => {
                r.tokens += it.tokens;
                r.events.extend(it.event);
                r.tool_use_ids.extend(use_id);
            }
            None => rows.push(ContentRow { part: it.part.clone(), label, tokens: it.tokens, events: it.event.into_iter().collect(), tool_use_ids: use_id.into_iter().collect() }),
        }
    }
    rows.sort_by_key(|r| std::cmp::Reverse(r.tokens));
    Some(Contents { lane: lane.id.clone(), call: call + 1, calls: lane.context.len(), event: point.event, total: point.total, rows })
}

/// `path` from the folder `dir`, when it is in it: `/p/x/a.md` in `/p` →
/// `x/a.md`. A path cut at the start (`…/p/x/a.md`, as `tool_summary` makes
/// it) works too. Any other text stays as it is.
pub fn in_folder<'a>(path: &'a str, dir: &str) -> &'a str {
    let dir = dir.trim_end_matches('/');
    if dir.is_empty() {
        return path;
    }
    if let Some(rest) = path.strip_prefix(dir).and_then(|r| r.strip_prefix('/')) {
        return rest;
    }
    let Some(cut) = path.strip_prefix('…') else { return path };
    // The longest start of `cut` that ends with `/` and is an end of `dir/`.
    let folder = format!("{dir}/");
    let mut best = None;
    for (i, c) in cut.char_indices() {
        if c == '/' && folder.ends_with(&cut[..=i]) {
            best = Some(i + 1);
        }
        if i >= folder.len() {
            break;
        }
    }
    match best {
        Some(k) if k < cut.len() => &cut[k..],
        _ => path,
    }
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
    fn each_call_holds_items_that_add_up_to_its_parts() {
        let mut r = LaneReader::main();
        for line in [
            json!({"type": "user", "timestamp": "2026-11-02T10:00:00Z", "message": {"content": "read both files"}}).to_string(),
            answer("01", "a1", 20_000, 100, json!([
                {"type": "tool_use", "id": "r1", "name": "Read", "input": {"file_path": "/p/big.md"}},
                {"type": "tool_use", "id": "r2", "name": "Read", "input": {"file_path": "/p/small.md"}}])),
            result("02", "r1", 3000),
            result("03", "r2", 1000),
            answer("04", "a2", 24_100, 50, json!([{"type": "tool_use", "id": "r3", "name": "Read", "input": {"file_path": "/p/big.md"}}])),
            result("05", "r3", 3000),
            answer("06", "a3", 27_150, 10, json!([])),
            // Thinking cleared: every item halves from here.
            answer("07", "a4", 13_575, 10, json!([])),
            json!({"type": "system", "subtype": "compact_boundary", "timestamp": "2026-11-02T10:00:08Z",
                   "compactMetadata": {"trigger": "manual", "preTokens": 13575, "postTokens": 3000}}).to_string(),
            answer("09", "a5", 23_000, 10, json!([])),
        ] {
            r.feed(&line);
        }
        let lane = r.finish();
        let at = |call: usize| -> Vec<(String, u64)> {
            items_at(&lane, call)
                .into_iter()
                .map(|it| {
                    let what = it.event.and_then(|e| lane.events[e].text.clone()).unwrap_or_else(|| it.part.clone());
                    (what, it.tokens)
                })
                .collect()
        };
        // Call 3: the second read of big.md is its own item.
        assert_eq!(
            at(2),
            [("Start", 20_000), ("/p/big.md", 3000), ("/p/big.md", 3000), ("/p/small.md", 1000), (OUTPUT, 100), (OUTPUT, 50)].map(|(a, b)| (a.to_string(), b))
        );
        assert_eq!(at(3)[0], ("Start".to_string(), 10_000));
        assert_eq!(at(3)[1], ("/p/big.md".to_string(), 1500));
        // After the compaction, only Start and the summary.
        assert_eq!(at(4), [("Start".to_string(), 20_000), ("Compacted (manual): 14K → 3K tokens".to_string(), 3000)]);
        // At every call, the items add up to each part.
        for (call, point) in lane.context.iter().enumerate() {
            for part in &point.parts {
                let sum: u64 = items_at(&lane, call).iter().filter(|it| it.part == part.name).map(|it| it.tokens).sum();
                assert_eq!(sum, part.tokens, "call {call} part {}", part.name);
            }
            assert_eq!(items_at(&lane, call).iter().map(|it| it.tokens).sum::<u64>(), point.total);
        }
    }

    #[test]
    fn contents_put_the_reads_of_one_file_and_all_answers_in_one_row() {
        let mut r = LaneReader::main();
        for line in [
            json!({"type": "user", "timestamp": "2026-11-02T10:00:00Z", "message": {"content": "read it"}}).to_string(),
            answer("01", "a1", 20_000, 100, json!([{"type": "tool_use", "id": "r1", "name": "Read", "input": {"file_path": "/p/big.md"}}])),
            result("02", "r1", 3000),
            answer("03", "a2", 23_100, 50, json!([{"type": "tool_use", "id": "r2", "name": "Read", "input": {"file_path": "/p/big.md"}}])),
            result("04", "r2", 1000),
            answer("05", "a3", 24_150, 10, json!([])),
        ] {
            r.feed(&line);
        }
        let lane = r.finish();
        let c = contents(&lane, 2, false, Some("/p"), &[]).unwrap();
        assert_eq!((c.call, c.calls, c.total), (3, 3, 24_150));
        let rows: Vec<(&str, u64, usize)> = c.rows.iter().map(|r| (r.label.as_str(), r.tokens, r.events.len())).collect();
        assert_eq!(rows, [("Start", 20_000, 0), ("big.md", 4000, 2), (OUTPUT, 150, 2)]);
        assert_eq!(c.rows[1].tool_use_ids, ["r1", "r2"]);
        let each = contents(&lane, 2, true, None, &[]).unwrap();
        assert_eq!(each.rows[1].label, "/p/big.md");
        assert_eq!(each.rows.len(), 5);
        assert_eq!(each.rows.iter().map(|r| r.tokens).sum::<u64>(), 24_150);
        assert!(contents(&lane, 3, false, None, &[]).is_none());
    }

    /// Claude Code cuts a long file's Read, and the agent reads the rest with
    /// `offset`. In "each" the two rows say which lines they hold, so they do
    /// not look like the same read twice. A whole file gets no range.
    #[test]
    fn each_addition_names_the_lines_of_a_partial_read() {
        let read = |t: &str, id: &str, start: u64, lines: u64, total: u64| {
            json!({"type": "user", "timestamp": format!("2026-11-02T10:00:{t}Z"),
                   "message": {"content": [{"type": "tool_result", "tool_use_id": id, "content": "x".repeat(1000)}]},
                   "toolUseResult": {"type": "text", "file": {"filePath": "/p/big.md", "startLine": start, "numLines": lines, "totalLines": total}}})
            .to_string()
        };
        let mut r = LaneReader::main();
        for line in [
            json!({"type": "user", "timestamp": "2026-11-02T10:00:00Z", "message": {"content": "read it"}}).to_string(),
            answer("01", "a1", 20_000, 100, json!([{"type": "tool_use", "id": "r1", "name": "Read", "input": {"file_path": "/p/big.md"}}])),
            read("02", "r1", 1, 289, 376),
            answer("03", "a2", 23_100, 50, json!([{"type": "tool_use", "id": "r2", "name": "Read", "input": {"file_path": "/p/big.md", "offset": 290, "limit": 90}}])),
            read("04", "r2", 290, 87, 376),
            answer("05", "a3", 24_150, 50, json!([{"type": "tool_use", "id": "r3", "name": "Read", "input": {"file_path": "/p/small.md"}}])),
            read("06", "r3", 1, 40, 40),
            answer("07", "a4", 25_200, 10, json!([])),
        ] {
            r.feed(&line);
        }
        let lane = r.finish();
        let each = contents(&lane, 3, true, Some("/p"), &[]).unwrap();
        let mut reads: Vec<&str> = each.rows.iter().filter(|r| r.part == tool_part("Read")).map(|r| r.label.as_str()).collect();
        reads.sort();
        assert_eq!(reads, ["big.md · lines 1–289 of 376", "big.md · lines 290–376 of 376", "small.md"]);
        // Grouped: one row per file, as before.
        let grouped = contents(&lane, 3, false, Some("/p"), &[]).unwrap();
        let big: Vec<(&str, usize)> = grouped.rows.iter().filter(|r| r.part == tool_part("Read")).map(|r| (r.label.as_str(), r.events.len())).collect();
        assert_eq!(big, [("big.md", 2), ("small.md", 1)]);
    }

    #[test]
    fn paths_are_shown_from_the_project_folder() {
        assert_eq!(in_folder("/Users/me/shop/src/a.rs", "/Users/me/shop"), "src/a.rs");
        assert_eq!(in_folder("/Users/me/shop/src/a.rs", "/Users/me/shop/"), "src/a.rs");
        assert_eq!(in_folder("/Users/me/shopping/a.rs", "/Users/me/shop"), "/Users/me/shopping/a.rs");
        assert_eq!(in_folder("…ers/me/shop/src/a.rs", "/Users/me/shop"), "src/a.rs");
        assert_eq!(in_folder("…ers/me/other/a.rs", "/Users/me/shop"), "…ers/me/other/a.rs");
        assert_eq!(in_folder("Read the plan", "/Users/me/shop"), "Read the plan");
        assert_eq!(in_folder("/Users/me/shop/a.rs", ""), "/Users/me/shop/a.rs");
    }

    /// A background subagent's report comes back as a meta user record, not
    /// as a tool result (checked 2026-11-07: 87% of the "Other" tokens of 686
    /// files were these). Its tokens are a part of their own.
    #[test]
    fn a_subagents_report_is_its_own_part_not_other() {
        let report = "Another Claude session sent a message:\n<agent-message from=\"af64\">\n[Subagent hand-back] The text below is the final report of a subagent. The report follows:\n  **Step 7 is done.** All checks pass.\n</agent-message>";
        let mut r = LaneReader::main().with_chat();
        for line in [
            json!({"type": "user", "timestamp": "2026-11-02T10:00:00Z", "message": {"content": "draft it"}}).to_string(),
            answer("01", "a1", 20_000, 100, json!([{"type": "tool_use", "id": "g1", "name": "Agent", "input": {"description": "Draft", "run_in_background": true}}])),
            result("02", "g1", 100),
            answer("03", "a2", 20_200, 50, json!([])),
            json!({"type": "user", "isMeta": true, "timestamp": "2026-11-02T10:00:04Z", "message": {"content": report}}).to_string(),
            answer("05", "a3", 23_250, 10, json!([])),
        ] {
            r.feed(&line);
        }
        let (lane, chat) = r.finish_with_chat();
        let e = lane.events.iter().position(|e| serde_json::to_value(e.kind).unwrap() == "report").expect("a report event");
        assert_eq!(lane.events[e].agent_id.as_deref(), Some("af64"));
        assert_eq!(lane.events[e].text.as_deref(), Some("**Step 7 is done.** All checks pass."));
        assert_eq!(lane.events[e].added_tokens, Some(3000));
        assert_eq!(chat.iter().find(|c| c.event == e).and_then(|c| c.text.as_deref()), Some(report));
        let last = lane.context.last().unwrap();
        let parts: Vec<(&str, u64)> = last.parts.iter().map(|p| (p.name.as_str(), p.tokens)).collect();
        assert!(parts.contains(&("Subagent reports", 3000)), "{parts:?}");
        assert!(!parts.iter().any(|(n, _)| *n == OTHER), "{parts:?}");
        // Spend: the call after the report is the report's, not "Other".
        let spend = crate::spend::analyze(std::slice::from_ref(&lane));
        let names: Vec<&str> = spend.causes.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"Subagent reports") && !names.contains(&"Other"), "{names:?}");
        // `ccop context` names the report by its subagent's lane.
        let mut helper = lane.clone();
        helper.id = "af64".into();
        helper.name = "Draft (general-purpose)".into();
        let rows = contents(&lane, 2, false, None, &[lane.clone(), helper]).unwrap().rows;
        assert!(rows.iter().any(|r| r.part == REPORTS && r.label == "Draft (general-purpose)" && r.tokens == 3000), "{rows:?}");
        let rows = contents(&lane, 2, true, None, &[]).unwrap().rows;
        assert!(rows.iter().any(|r| r.label == "from af64: **Step 7 is done.** All checks pass."), "{rows:?}");
    }

    #[test]
    fn split_adds_up_exactly() {
        assert_eq!(split(10, &[1, 1, 1]), Some(vec![4, 3, 3]));
        assert_eq!(split(7, &[0, 0]), Some(vec![4, 3]));
        assert_eq!(split(5, &[]), None);
        assert_eq!(split(0, &[5, 5]), Some(vec![0, 0]));
    }
}
