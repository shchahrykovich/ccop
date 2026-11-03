//! Where the API-equivalent cost of one session went, and what to change to
//! spend less. Part of `ccop anatomy --json`; the app's Spend tab shows it.
//!
//! Every model call reads the whole context again, so a session costs about
//! (number of model calls) × (context size). A model call runs because
//! something came back: tool results, a prompt, or a task from the lead. This
//! module puts the cost of each call on what made it run (split evenly when
//! several tool results came back together), so "Bash: 70%" means: the calls
//! that read Bash results cost 70% of the session.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::anatomy::{Event, EventKind, Lane};
use crate::pricing::{cost_micros, price};
use crate::usage::{Usage, short};

/// An agent whose calls read more than this on average gets a tip.
pub const BIG_CONTEXT: u64 = 100_000;
/// A tool result that added more than this to a context gets a tip.
pub const BIG_RESULT: u64 = 10_000;
/// A tool needs this many calls for the "fewer calls" tip.
pub const MANY_CALLS: u64 = 10;
const SONNET: &str = "claude-sonnet-5-5";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Spend {
    /// API-equivalent cost of every model call of the session.
    pub cost_micros: u64,
    pub tokens: u64,
    /// What made the model run, the most cost first.
    pub causes: Vec<Cause>,
    /// One per lane, in the order of `Anatomy.lanes`.
    pub lanes: Vec<LaneSpend>,
    /// What to change, the most money first.
    pub tips: Vec<Tip>,
    /// Bash calls by the program they ran (`anatomy::command_group`), the most cost first.
    pub commands: Vec<CommandGroup>,
    /// Failed tool calls with the same start of error text, the most first.
    pub errors: Vec<ErrorGroup>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CommandGroup {
    /// `sed`, `node build.js context`, `python3 (inline script)`, `for loop`, ...
    pub group: String,
    pub calls: u64,
    pub errors: u64,
    /// The cost of the model calls after these calls (see `Cause`).
    pub cost_micros: u64,
    pub result_bytes: u64,
    /// The first call's summary: its description, or its command.
    pub example: Option<String>,
    /// Every call of the group, in the order of the lanes and their events.
    pub items: Vec<CallCost>,
}

/// One tool call and the cost of the model call after it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CallCost {
    /// `Lane.id`.
    pub lane: String,
    /// The index of the call in `Lane.events`.
    pub event: usize,
    /// Its part of the model call after it (see `Cause`).
    pub cost_micros: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorGroup {
    pub tool: String,
    /// The error text of the first of these calls.
    pub message: String,
    pub count: u64,
    /// The cost of the model calls after these calls.
    pub cost_micros: u64,
    /// The first call's summary.
    pub example: Option<String>,
    /// Why such calls fail and what to do, for errors ccop knows (`explain`).
    pub cause: Option<String>,
    /// Worktree refusals are grouped by their kind, not by their text.
    pub refusal: Option<Refusal>,
}

/// Errors are grouped by this many characters from their start: messages
/// that differ only in their end (a file name, a variable) go together.
pub const ERROR_KEY_CHARS: usize = 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CauseKind {
    /// A person's prompt in the main session.
    Prompt,
    /// The prompt of a subagent: the task its lead gave it.
    Task,
    Tool,
    Compact,
    /// A model call with nothing before it in its lane.
    Other,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Cause {
    pub kind: CauseKind,
    /// The tool's name, or `Your prompts`, `Tasks from the lead`, `Compaction`, `Other`.
    pub name: String,
    /// Tool calls, prompts or compactions.
    pub count: u64,
    /// Tool calls that failed.
    pub errors: u64,
    /// Model calls this cause made run; a call after three tool results
    /// counts a third for each.
    pub model_calls: f64,
    pub cost_micros: u64,
    pub tokens: u64,
    /// The part of `cost_micros` that came after failed calls.
    pub error_cost_micros: u64,
    /// The average context those model calls read.
    pub avg_context: u64,
    /// Tokens this cause added to contexts. Estimated (see `context.rs`).
    pub added_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaneSpend {
    pub lane: String,
    pub cost_micros: u64,
    pub model_calls: u64,
    pub avg_context: u64,
    pub max_context: u64,
    /// The context of the lane's first call.
    pub start_context: u64,
    /// The same calls at Claude Sonnet 5.5 prices; None when the lane does
    /// not run on a model that costs more.
    pub sonnet_cost_micros: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TipKind {
    ManyCalls,
    Errors,
    Model,
    BigContext,
    BigResults,
    CacheRewrites,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tip {
    pub kind: TipKind,
    pub title: String,
    pub detail: String,
    /// The cost the tip is about.
    pub cost_micros: u64,
    /// What the change could save, when ccop can compute it.
    pub saving_micros: Option<u64>,
}

/// The API-equivalent cost of one event: an answer's call; 0 for others.
pub fn event_cost(e: &Event) -> u64 {
    match (e.kind, &e.usage) {
        (EventKind::Answer, Some(u)) => cost_micros(e.model.as_deref().unwrap_or_default(), u),
        _ => 0,
    }
}

pub fn lane_cost(lane: &Lane) -> u64 {
    lane.events.iter().map(event_cost).sum()
}

fn context_of(e: &Event) -> u64 {
    e.context_tokens.or(e.usage.map(|u| u.input_total())).unwrap_or(0)
}

#[derive(Default)]
struct Acc {
    count: u64,
    errors: u64,
    calls: f64,
    cost: f64,
    tokens: f64,
    error_cost: f64,
    context: f64,
    added: u64,
}

pub fn analyze(lanes: &[Lane]) -> Spend {
    analyze_with_paid(lanes).0
}

/// What one prompt, tool call or compaction paid of the model call after it:
/// its cost and its tokens (input, cache write, cache read and output), split
/// evenly when several results came back together.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Paid {
    pub cost_micros: f64,
    pub tokens: f64,
}

/// The spend, and what each prompt, tool call or compaction paid of the
/// model call after it, by (lane index, event index).
pub fn analyze_with_paid(lanes: &[Lane]) -> (Spend, BTreeMap<(usize, usize), Paid>) {
    let mut causes: BTreeMap<(CauseKind, String), Acc> = BTreeMap::new();
    // The cost of the model call after each prompt, tool call or compaction, by (lane, event).
    let mut after: BTreeMap<(usize, usize), f64> = BTreeMap::new();
    let mut paid: BTreeMap<(usize, usize), Paid> = BTreeMap::new();
    for (li, lane) in lanes.iter().enumerate() {
        // What came back since the last model call: (cause, failed, event).
        let mut since: Vec<((CauseKind, String), bool, Option<usize>)> = Vec::new();
        for (ei, e) in lane.events.iter().enumerate() {
            let key = match e.kind {
                EventKind::Prompt if lane.id == "main" => (CauseKind::Prompt, "Your prompts".to_string()),
                EventKind::Prompt => (CauseKind::Task, "Tasks from the lead".to_string()),
                EventKind::Tool => (CauseKind::Tool, e.tool.clone().unwrap_or_else(|| "Tool".into())),
                EventKind::Compact => (CauseKind::Compact, "Compaction".to_string()),
                EventKind::Error => continue,
                EventKind::Answer => {
                    let Some(u) = e.usage else { continue };
                    if since.is_empty() {
                        since.push(((CauseKind::Other, "Other".to_string()), false, None));
                    }
                    let n = since.len() as f64;
                    let (cost, tokens, ctx) = (event_cost(e) as f64, u.total() as f64, context_of(e) as f64);
                    for (key, failed, event) in since.drain(..) {
                        if let Some(t) = event {
                            *after.entry((li, t)).or_default() += cost / n;
                            let p = paid.entry((li, t)).or_default();
                            p.cost_micros += cost / n;
                            p.tokens += tokens / n;
                        }
                        let a = causes.entry(key).or_default();
                        a.calls += 1.0 / n;
                        a.cost += cost / n;
                        a.tokens += tokens / n;
                        a.context += ctx / n;
                        if failed {
                            a.error_cost += cost / n;
                        }
                    }
                    continue;
                }
            };
            let a = causes.entry(key.clone()).or_default();
            a.count += 1;
            a.errors += e.is_error as u64;
            if e.kind != EventKind::Compact {
                a.added += e.added_tokens.unwrap_or(0);
            }
            since.push((key, e.is_error, Some(ei)));
        }
    }
    let (commands, errors) = groups(lanes, &after);
    let mut causes: Vec<Cause> = causes
        .into_iter()
        .map(|((kind, name), a)| Cause {
            kind,
            name,
            count: a.count,
            errors: a.errors,
            model_calls: a.calls,
            cost_micros: a.cost.round() as u64,
            tokens: a.tokens.round() as u64,
            error_cost_micros: a.error_cost.round() as u64,
            avg_context: if a.calls > 0.0 { (a.context / a.calls).round() as u64 } else { 0 },
            added_tokens: a.added,
        })
        .collect();
    causes.sort_by(|a, b| b.cost_micros.cmp(&a.cost_micros).then(a.name.cmp(&b.name)));

    let lane_spends: Vec<LaneSpend> = lanes.iter().map(lane_spend).collect();
    let cost_micros = lane_spends.iter().map(|l| l.cost_micros).sum();
    let tokens = lanes.iter().map(|l| l.usage.total()).sum();
    let mut tips = Vec::new();
    if cost_micros > 0 {
        tips.extend(many_calls(&causes, &commands, cost_micros));
        tips.extend(error_tip(&causes, &errors, cost_micros));
        tips.extend(model(lanes, &lane_spends, cost_micros));
        tips.extend(big_context(lanes, &lane_spends, cost_micros));
        tips.extend(big_results(lanes, cost_micros));
        tips.extend(cache_rewrites(lanes, cost_micros));
    }
    tips.sort_by_key(|t| std::cmp::Reverse(t.saving_micros.unwrap_or(t.cost_micros)));
    (Spend { cost_micros, tokens, causes, lanes: lane_spends, tips, commands, errors }, paid)
}

/// Bash calls by program, and failed calls by the start of their error.
fn groups(lanes: &[Lane], after: &BTreeMap<(usize, usize), f64>) -> (Vec<CommandGroup>, Vec<ErrorGroup>) {
    #[derive(Default)]
    struct G {
        calls: u64,
        errors: u64,
        cost: f64,
        bytes: u64,
        example: Option<String>,
        items: Vec<CallCost>,
        message: String,
        tool: String,
        cause: Option<String>,
        refusal: Option<Refusal>,
    }
    let mut commands: BTreeMap<String, G> = BTreeMap::new();
    let mut errors: BTreeMap<(String, String), G> = BTreeMap::new();
    for (li, lane) in lanes.iter().enumerate() {
        for (ei, e) in lane.events.iter().enumerate().filter(|(_, e)| e.kind == EventKind::Tool) {
            let cost = after.get(&(li, ei)).copied().unwrap_or(0.0);
            if let Some(group) = &e.group {
                let g = commands.entry(group.clone()).or_default();
                g.calls += 1;
                g.errors += e.is_error as u64;
                g.cost += cost;
                g.bytes += e.result_bytes.unwrap_or(0);
                g.example = g.example.take().or_else(|| e.text.clone());
                g.items.push(CallCost { lane: lane.id.clone(), event: ei, cost_micros: cost.round() as u64 });
            }
            if e.is_error {
                let tool = e.tool.clone().unwrap_or_else(|| "Tool".into());
                let message = e.error.clone().unwrap_or_else(|| "(no error text)".into());
                let key: String = match e.refusal {
                    Some(r) => format!("refusal {r:?}"),
                    None => message.chars().take(ERROR_KEY_CHARS).collect(),
                };
                let g = errors.entry((tool.clone(), key)).or_default();
                g.calls += 1;
                g.cost += cost;
                if g.message.is_empty() {
                    g.refusal = e.refusal;
                    g.cause = match e.refusal {
                        Some(r) => Some(r.cause()),
                        None => explain(&message, e.group.as_deref()).map(str::to_string),
                    };
                    g.message = message;
                    g.tool = tool;
                    g.example = e.text.clone();
                }
            }
        }
    }
    let mut commands: Vec<CommandGroup> = commands
        .into_iter()
        .map(|(group, g)| CommandGroup {
            group,
            calls: g.calls,
            errors: g.errors,
            cost_micros: g.cost.round() as u64,
            result_bytes: g.bytes,
            example: g.example,
            items: g.items,
        })
        .collect();
    commands.sort_by_key(|c| std::cmp::Reverse(c.cost_micros));
    let mut errors: Vec<ErrorGroup> = errors
        .into_values()
        .map(|g| ErrorGroup {
            tool: g.tool,
            message: g.message,
            count: g.calls,
            cost_micros: g.cost.round() as u64,
            example: g.example,
            cause: g.cause,
            refusal: g.refusal,
        })
        .collect();
    errors.sort_by(|a, b| b.count.cmp(&a.count).then(b.cost_micros.cmp(&a.cost_micros)));
    (commands, errors)
}

fn lane_spend(lane: &Lane) -> LaneSpend {
    let answers: Vec<&Event> = lane.events.iter().filter(|e| e.kind == EventKind::Answer && e.usage.is_some()).collect();
    let contexts: Vec<u64> = answers.iter().map(|e| context_of(e)).collect();
    let costs_more = lane.model.as_deref().is_some_and(|m| price(m, 0).input > price(SONNET, 0).input);
    LaneSpend {
        lane: lane.id.clone(),
        cost_micros: lane_cost(lane),
        model_calls: answers.len() as u64,
        avg_context: if contexts.is_empty() { 0 } else { contexts.iter().sum::<u64>() / contexts.len() as u64 },
        max_context: contexts.iter().copied().max().unwrap_or(0),
        start_context: contexts.first().copied().unwrap_or(0),
        sonnet_cost_micros: costs_more.then(|| answers.iter().map(|e| cost_micros(SONNET, &e.usage.unwrap())).sum()),
    }
}

/// A tool whose results made the model run for a large part of the cost.
fn many_calls(causes: &[Cause], commands: &[CommandGroup], total: u64) -> Vec<Tip> {
    causes
        .iter()
        .filter(|c| c.kind == CauseKind::Tool && c.count >= MANY_CALLS && c.cost_micros * 5 >= total)
        .map(|c| {
            // For Bash: the programs with the most calls.
            let mut top: Vec<&CommandGroup> = if c.name == "Bash" { commands.iter().collect() } else { Vec::new() };
            top.sort_by(|a, b| b.calls.cmp(&a.calls).then(a.group.cmp(&b.group)));
            let most = if top.is_empty() {
                String::new()
            } else {
                let list = top.iter().take(5).map(|g| format!("{} {}", g.group, g.calls)).collect::<Vec<_>>().join(", ");
                format!(" Most calls: {list}.")
            };
            Tip {
                kind: TipKind::ManyCalls,
                title: format!("{} calls made the model run for {} of the cost ({})", c.name, percent(c.cost_micros, total), dollars(c.cost_micros)),
                detail: format!(
                    "{} {} calls.{most} After each result the model runs again and reads the whole context again: {} tokens \
                     on average. Join small steps into one command or one script, and ask for short output.",
                    c.count,
                    c.name,
                    short(c.avg_context)
                ),
                cost_micros: c.cost_micros,
                saving_micros: None,
            }
        })
        .collect()
}

/// Failed tool calls: each one usually means one more model call to try again.
fn error_tip(causes: &[Cause], errors: &[ErrorGroup], total: u64) -> Option<Tip> {
    let count: u64 = causes.iter().map(|c| c.errors).sum();
    let cost: u64 = causes.iter().map(|c| c.error_cost_micros).sum();
    if count < 3 || cost * 50 < total {
        return None;
    }
    let mut by_tool: Vec<&Cause> = causes.iter().filter(|c| c.errors > 0).collect();
    by_tool.sort_by(|a, b| b.errors.cmp(&a.errors).then(a.name.cmp(&b.name)));
    let list = by_tool.iter().map(|c| format!("{} {}", c.name, c.errors)).collect::<Vec<_>>().join(", ");
    // Worktree refusals: one sentence with a count and a fix for each kind.
    let refused: Vec<&ErrorGroup> = errors.iter().filter(|e| e.refusal.is_some()).collect();
    let refused = if refused.is_empty() {
        String::new()
    } else {
        let n: u64 = refused.iter().map(|e| e.count).sum();
        let kinds = refused
            .iter()
            .filter_map(|e| e.refusal.map(|r| format!("{}× {}: {}", e.count, r.label(), r.fix())))
            .collect::<Vec<_>>()
            .join("; ");
        format!(
            "{n}× Claude Code refused to run the command, because the session works in its own git worktree and Claude Code \
             could not show from the command's text that it does not run git outside it: {kinds}. Write these rules in the \
             project's CLAUDE.md, so that every agent reads them before it writes a command."
        )
    };
    // The three most frequent other reasons: ccop's explanation, else the error text.
    let why = errors
        .iter()
        .filter(|e| e.refusal.is_none())
        .take(3)
        .map(|e| match &e.cause {
            Some(cause) => format!("{}× {cause}", e.count),
            None => {
                let text: String = e.message.chars().take(140).collect();
                let cut = if e.message.chars().count() > 140 { "…" } else { "" };
                format!("{}× \"{text}{cut}\".", e.count)
            }
        })
        .collect::<Vec<_>>()
        .join(" ");
    Some(Tip {
        kind: TipKind::Errors,
        title: format!("{count} tool calls failed; the model calls after them cost {}", dollars(cost)),
        detail: format!(
            "Failed: {list}. Why: {} Each failed call costs one more model call to try again.",
            [refused, why].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ")
        ),
        cost_micros: cost,
        saving_micros: Some(cost),
    })
}

/// Subagents on a model that costs more than Sonnet.
fn model(lanes: &[Lane], spends: &[LaneSpend], total: u64) -> Option<Tip> {
    let mut picked: Vec<(&Lane, &LaneSpend, u64)> = lanes
        .iter()
        .zip(spends)
        .filter(|(l, _)| l.id != "main")
        .filter_map(|(l, s)| s.sonnet_cost_micros.map(|sonnet| (l, s, sonnet)))
        .collect();
    let cost: u64 = picked.iter().map(|(_, s, _)| s.cost_micros).sum();
    let sonnet: u64 = picked.iter().map(|(_, _, x)| x).sum();
    let saving = cost.saturating_sub(sonnet);
    if picked.is_empty() || saving * 20 < total {
        return None;
    }
    let mut models: Vec<String> = picked.iter().filter_map(|(l, _, _)| l.model.as_deref().map(model_name)).collect();
    models.sort();
    models.dedup();
    picked.sort_by_key(|p| std::cmp::Reverse(p.1.cost_micros));
    let top = picked.iter().take(3).map(|(l, s, _)| format!("{} ({})", l.name, dollars(s.cost_micros))).collect::<Vec<_>>().join(", ");
    Some(Tip {
        kind: TipKind::Model,
        title: format!(
            "{} subagent{} on {} cost {}; on Sonnet 5.5 about {}",
            picked.len(),
            if picked.len() == 1 { "" } else { "s" },
            models.join(", "),
            dollars(cost),
            dollars(sonnet)
        ),
        detail: format!(
            "The most expensive: {top}. For work that does not need the largest model, set `model: sonnet` in the agent's \
             definition or ask for Sonnet when you start it. Compare the quality on one task first."
        ),
        cost_micros: cost,
        saving_micros: Some(saving),
    })
}

/// Agents whose calls read a large context: the part above the start is
/// what the work added, and every call reads it again.
fn big_context(lanes: &[Lane], spends: &[LaneSpend], total: u64) -> Option<Tip> {
    let mut picked: Vec<(&Lane, &LaneSpend, u64)> = lanes
        .iter()
        .zip(spends)
        .filter(|(_, s)| s.avg_context >= BIG_CONTEXT && s.model_calls >= MANY_CALLS)
        .map(|(l, s)| {
            let growth = l
                .events
                .iter()
                .filter(|e| e.kind == EventKind::Answer && e.usage.is_some())
                .map(|e| {
                    let extra = context_of(e).saturating_sub(s.start_context);
                    cost_micros(e.model.as_deref().unwrap_or_default(), &Usage { cache_read_tokens: extra, requests: 1, ..Usage::default() })
                })
                .sum();
            (l, s, growth)
        })
        .collect();
    let cost: u64 = picked.iter().map(|(_, _, g)| g).sum();
    if picked.is_empty() || cost * 20 < total {
        return None;
    }
    picked.sort_by_key(|p| std::cmp::Reverse(p.2));
    let list = picked
        .iter()
        .take(3)
        .map(|(l, s, _)| format!("{}: {} on average, up to {}, {} calls", l.name, short(s.avg_context), short(s.max_context), s.model_calls))
        .collect::<Vec<_>>()
        .join("; ");
    Some(Tip {
        kind: TipKind::BigContext,
        title: format!(
            "{} agent{} read over {} tokens of context per call; reading what the work added cost {}",
            picked.len(),
            if picked.len() == 1 { "" } else { "s" },
            short(BIG_CONTEXT),
            dollars(cost)
        ),
        detail: format!(
            "{list}. Every call reads the whole context again. Give an agent a smaller task, start a new agent for each \
             part of the work, or compact earlier."
        ),
        cost_micros: cost,
        saving_micros: None,
    })
}

/// Large tool results: the next call writes them to the cache, and every
/// later call of the lane reads them again until a compaction.
fn big_results(lanes: &[Lane], total: u64) -> Option<Tip> {
    let mut found: Vec<(&Event, u64, u64)> = Vec::new();
    for lane in lanes {
        for (i, e) in lane.events.iter().enumerate() {
            let added = e.added_tokens.unwrap_or(0);
            if e.kind != EventKind::Tool || added < BIG_RESULT {
                continue;
            }
            let mut later: u64 = 0;
            let mut cost = 0;
            for next in &lane.events[i + 1..] {
                match (next.kind, next.usage) {
                    (EventKind::Compact, _) => break,
                    (EventKind::Answer, Some(u)) => {
                        let tokens = if later == 0 {
                            // Written once, with the write time-to-live of that call.
                            let one_hour = if u.cache_write_1h_tokens > 0 { added } else { 0 };
                            Usage { cache_write_tokens: added, cache_write_1h_tokens: one_hour, requests: 1, ..Usage::default() }
                        } else {
                            Usage { cache_read_tokens: added, requests: 1, ..Usage::default() }
                        };
                        later += 1;
                        cost += cost_micros(next.model.as_deref().unwrap_or_default(), &tokens);
                    }
                    _ => {}
                }
            }
            // The calls after the one that wrote it.
            found.push((e, later.saturating_sub(1), cost));
        }
    }
    let cost: u64 = found.iter().map(|(_, _, c)| c).sum();
    if found.is_empty() || cost * 20 < total {
        return None;
    }
    let tokens: u64 = found.iter().map(|(e, _, _)| e.added_tokens.unwrap_or(0)).sum();
    found.sort_by_key(|f| std::cmp::Reverse(f.2));
    // Claude Code saves a command output that is too long to `<session>/tool-results/`; the model then reads it.
    let saved = if found.iter().any(|(e, _, _)| e.text.as_deref().is_some_and(|t| t.contains("/tool-results/"))) {
        " Files in tool-results are command outputs that were too long, so Claude Code saved them to a file, and the model then read them."
    } else {
        ""
    };
    let list = found
        .iter()
        .take(3)
        .map(|(e, later, _)| {
            format!(
                "{} {}: {} tokens, read again by {} later call{}",
                e.tool.as_deref().unwrap_or("Tool"),
                short_path(e.text.as_deref().unwrap_or("")),
                short(e.added_tokens.unwrap_or(0)),
                later,
                if *later == 1 { "" } else { "s" }
            )
        })
        .collect::<Vec<_>>()
        .join("; ");
    Some(Tip {
        kind: TipKind::BigResults,
        title: format!(
            "{} tool result{} of over {} tokens ({} in all) stayed in the context; writing them to the cache and reading them again cost {}",
            found.len(),
            if found.len() == 1 { "" } else { "s" },
            short(BIG_RESULT),
            short(tokens),
            dollars(cost)
        ),
        detail: format!(
            "The largest: {list}.{saved} Read only the lines you need (Read with offset and limit), and filter command \
             output (grep, head, tail) before it reaches the model."
        ),
        cost_micros: cost,
        saving_micros: None,
    })
}

/// Calls that read much less from the cache than the call before them had
/// in its context: the cache expired after a pause, or the start of the
/// context changed, so the context was written to the cache again.
fn cache_rewrites(lanes: &[Lane], total: u64) -> Option<Tip> {
    let mut count = 0;
    let mut extra = 0u64;
    for lane in lanes {
        // The context of the previous call; None after a compaction.
        let mut previous: Option<u64> = None;
        for e in &lane.events {
            match (e.kind, e.usage) {
                (EventKind::Compact, _) => previous = None,
                (EventKind::Answer, Some(u)) => {
                    if let Some(prev) = previous.filter(|p| *p >= 20_000 && u.cache_read_tokens * 2 < *p) {
                        // Written again although the previous call had cached it.
                        let lost = u.cache_write_tokens.min(prev - u.cache_read_tokens);
                        let model = e.model.as_deref().unwrap_or_default();
                        let read = Usage {
                            cache_read_tokens: u.cache_read_tokens + lost,
                            cache_write_tokens: u.cache_write_tokens - lost,
                            cache_write_1h_tokens: u.cache_write_1h_tokens.saturating_sub(lost),
                            ..u
                        };
                        count += 1;
                        extra += cost_micros(model, &u).saturating_sub(cost_micros(model, &read));
                    }
                    previous = Some(context_of(e));
                }
                _ => {}
            }
        }
    }
    if count == 0 || extra * 33 < total {
        return None;
    }
    Some(Tip {
        kind: TipKind::CacheRewrites,
        title: format!("{count} time{} the whole context was written to the cache again: {} more than reading it", if count == 1 { "" } else { "s" }, dollars(extra)),
        detail: "A call writes the context again when the cache expired (after a pause of 5 minutes, or 1 hour) or when \
                 the start of the context changed (another model, other tools, a changed CLAUDE.md). Avoid long pauses \
                 in the middle of a task, or start a new session after one."
            .into(),
        cost_micros: extra,
        saving_micros: Some(extra),
    })
}

/// What kind of command Claude Code refused to run in a session that works
/// in its own git worktree. Claude Code reads only the text of a command and
/// refuses it when it cannot show from the text that the command does not
/// run git outside the worktree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Refusal {
    /// `for f in a b; do sed -n 1p $f.md; done`: the loop variable.
    Loop,
    /// `sed -n 1p a.md | node check.js -`: text piped into a program.
    Stdin,
    /// `R=/p; sed -n 1p $R/a.md`: a path or program in a shell variable.
    Variable,
    /// `... | xargs sh -c '...'`, `find -exec`.
    Xargs,
    /// git inside a longer command.
    Git,
    /// Shell functions, long chains: too complex to check.
    Complex,
    /// A worktree refusal of another kind.
    Other,
}

impl Refusal {
    /// What the command did, with an example.
    pub fn label(self) -> &'static str {
        match self {
            Refusal::Loop => "a `for` loop over files (`for f in a b; do sed -n 1,9p $f.md; done`)",
            Refusal::Stdin => "text piped into a program (`sed -n 1,9p a.md | node check.js -`)",
            Refusal::Variable => "a path or program in a shell variable (`R=/path; sed -n 1,9p $R/a.md`)",
            Refusal::Xargs => "`xargs` or `find -exec` (`grep -l x *.md | xargs sh -c '...'`)",
            Refusal::Git => "git inside a longer command",
            Refusal::Complex => "a command too complex to check (a long `<<EOF` text, a shell function, a long chain)",
            Refusal::Other => "a glob (`logs/02-*/`) or another part Claude Code cannot check",
        }
    }

    /// What to write instead.
    pub fn fix(self) -> &'static str {
        match self {
            Refusal::Loop => {
                "give all the files to one command (`grep -n -A30 '^## Outline' a.md b.md`), or put the loop in a script file and run the script"
            }
            Refusal::Stdin => "pass a file path instead: write the text to a file first, or give the program an option that reads the file",
            Refusal::Variable => "write the full path in every command",
            Refusal::Xargs => "run the plain command on the files",
            Refusal::Git => "run git as its own command, from the worktree folder",
            Refusal::Complex => "write texts and scripts to a file with the Write tool, and split the rest into plain, separate commands",
            Refusal::Other => "use plain commands with full paths, and run git from the worktree folder",
        }
    }

    /// The `cause` of an error group of this kind.
    pub fn cause(self) -> String {
        format!(
            "Claude Code refused to run the command: {}. In a session with its own git worktree, Claude Code runs only \
             commands that it can show do not run git outside the worktree. Instead, {}.",
            self.label(),
            self.fix()
        )
    }
}

/// The kind of a worktree refusal, from the refused `command` and the whole
/// error text Claude Code gave (checked in Claude Code 2.1.317). The text
/// names the part it could not check: "feeds node a descriptor", "the
/// variable f", "find -exec or xargs". None for other errors.
pub fn refusal(command: &str, message: &str) -> Option<Refusal> {
    let has = |s: &str| message.contains(s);
    if !has("isolated in the worktree") {
        return None;
    }
    let variable = message.split_once("(the variable ").and_then(|(_, rest)| rest.split_once(')')).map(|(name, _)| name.trim());
    Some(if has("a descriptor") {
        Refusal::Stdin
    } else if has("find -exec or xargs") {
        Refusal::Xargs
    } else if has("names git") {
        Refusal::Git
    } else if has("(a glob pattern)") {
        Refusal::Other
    } else if let Some(v) = variable.filter(|v| !v.is_empty()) {
        let loops = [format!("for {v} in "), format!("while read {v}"), format!("while read -r {v}")];
        if loops.iter().any(|l| command.contains(l.as_str())) { Refusal::Loop } else { Refusal::Variable }
    } else if has("computed at runtime") {
        Refusal::Variable
    } else if has("too complex") {
        Refusal::Complex
    } else {
        Refusal::Other
    })
}

/// Why a tool call failed and what to do, for error texts ccop knows;
/// `group` is the Bash program (`anatomy::command_group`). The text starts
/// with a short label and a colon. The texts are written by hand in ccop, not
/// given by Claude Code. The worktree one follows Claude Code's own messages
/// (checked in Claude Code 2.1.317: "cannot be shown not to be git"); the
/// others are general rules (grep exits 1 when nothing matches, and so on).
pub fn explain(message: &str, group: Option<&str>) -> Option<&'static str> {
    let m = message.to_ascii_lowercase();
    let has = |s: &str| m.contains(s);
    Some(if has("isolated in the worktree") {
        "Claude Code refused to run the command: the session works in its own git worktree, and Claude Code lets git \
         work only on that worktree. With a variable, a glob (`*`), a loop or a complex git command, Claude Code cannot \
         show that the command does not run git somewhere else, so it does not run it. Use plain commands with full \
         paths, and run git from the worktree folder."
    } else if has("unexpected argument") || has("unknown option") || has("invalid option") || has("unrecognized") || has("usage:") {
        "Wrong arguments for the program: fix the usage written in the skill or agent instructions, or make the \
         program's error message show the right form."
    } else if has("string to replace not found") {
        "Edit could not find the text to replace: the file changed, or the text was not copied exactly. Read the file again first."
    } else if has("file has not been read yet") {
        "Edit or Write before Read: the session must read a file before it changes it."
    } else if has("command not found") {
        "A program that is not installed: the shell could not find it (not installed, or not on the PATH)."
    } else if has("no such file or directory") || has("does not exist") {
        "A wrong path: the file or folder is not there. Give the agent the real paths, or let it list the folder first."
    } else if has("syntaxerror") || has("syntax error") || has("unexpected eof") || has("unterminated") {
        "A script written inside the command has a syntax error: often from quotes inside quotes. Put longer scripts in a file."
    } else if has("permission denied") || has("requires approval") || has("was blocked") || has("doesn't want to proceed") {
        "The call was not allowed: by file permissions, settings, a hook, or the person."
    } else if has("timed out") {
        "The command ran too long and was stopped: make it do less, or run it in the background."
    } else if group == Some("grep") && m.trim() == "exit code 1" {
        "grep found no match: exit code 1 here is not a real failure, but Claude Code shows it as one. Add `|| true`."
    } else {
        return None;
    })
}

/// A path as its last two parts: `/a/b/c/d.md` → `…/c/d.md`; other text as it is.
fn short_path(text: &str) -> String {
    let parts: Vec<&str> = text.split('/').filter(|p| !p.is_empty()).collect();
    let is_path = text.starts_with('/') || text.starts_with('…');
    if !is_path || text.contains(' ') || parts.len() <= 2 {
        return text.to_string();
    }
    format!("…/{}", parts[parts.len() - 2..].join("/"))
}

/// `claude-opus-5-5` → `Opus 5.5`.
fn model_name(model: &str) -> String {
    let m = model.strip_prefix("claude-").unwrap_or(model);
    let mut parts = m.split('-');
    let family = parts.next().unwrap_or_default();
    let version: Vec<&str> = parts.take_while(|p| p.len() <= 2 && p.chars().all(|c| c.is_ascii_digit())).collect();
    let mut name = family.chars().next().map(|c| c.to_ascii_uppercase().to_string() + &family[1..]).unwrap_or_default();
    if !version.is_empty() {
        name += &format!(" {}", version.join("."));
    }
    name
}

pub fn dollars(micros: u64) -> String {
    format!("${:.2}", micros as f64 / 1e6)
}

fn percent(part: u64, total: u64) -> String {
    format!("{:.0}%", part as f64 * 100.0 / total.max(1) as f64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::anatomy::{LaneMeta, LaneReader, build};
    use serde_json::{Value, json};

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

    /// An Opus 5.5 call: 1 input, `read` cache read, `write` cache write (1 hour), `out` output.
    fn answer(t: &str, id: &str, read: u64, write: u64, out: u64, blocks: Value) -> Value {
        json!({"type": "assistant", "requestId": format!("r{id}"), "timestamp": format!("2026-11-02T10:{t}Z"),
               "message": {"id": id, "model": "claude-opus-5-5", "content": blocks,
                           "usage": {"input_tokens": 1, "cache_read_input_tokens": read, "cache_creation_input_tokens": write,
                                     "cache_creation": {"ephemeral_1h_input_tokens": write}, "output_tokens": out}}})
    }

    fn tool(id: &str, name: &str, desc: &str) -> Value {
        json!({"type": "tool_use", "id": id, "name": name, "input": {"command": desc, "description": desc, "file_path": desc}})
    }

    fn result(t: &str, use_id: &str, text: &str, error: bool) -> Value {
        json!({"type": "user", "timestamp": format!("2026-11-02T10:{t}Z"),
               "message": {"content": [{"type": "tool_result", "tool_use_id": use_id, "content": text, "is_error": error}]}})
    }

    // Opus 5.5 per token in µ$: input 4, output 20, 1-hour write 8, read 0.20.
    // Sonnet 5.5: input 2, output 10, 1-hour write 4, read 0.20.

    #[test]
    fn each_call_is_paid_by_what_made_it_run() {
        let main = lane(
            LaneReader::main(),
            &[
                prompt("00:00", "go"),
                // 4 + 100×0.2 + 10×20 = 224, made to run by the prompt.
                answer("00:01", "m1", 100, 0, 10, json!([tool("t1", "Bash", "ls"), tool("t2", "Read", "/p/a.md")])),
                result("00:02", "t1", "a", false),
                result("00:02", "t2", "no such file", true),
                // 4 + 20 + 400 = 424: half for Bash, half for Read (after its error).
                answer("00:03", "m2", 100, 0, 20, json!([tool("t3", "Bash", "pwd")])),
                result("00:04", "t3", "/p", false),
                // 24, all Bash.
                answer("00:05", "m3", 100, 0, 0, json!([])),
            ],
        );
        let sub = lane(
            LaneReader::subagent("a1", LaneMeta { description: Some("Draft".into()), ..LaneMeta::default() }),
            &[
                json!({"type": "user", "isSidechain": true, "timestamp": "2026-11-02T10:00:02Z", "message": {"content": "Draft it"}}),
                // Opus: 4 + 20 + 2,000 = 2,024; Sonnet: 2 + 20 + 1,000 = 1,022.
                answer("00:30", "s1", 100, 0, 100, json!([])),
            ],
        );
        let a = build("s", main, vec![sub]);
        let s = &a.spend;
        assert_eq!(s.cost_micros, 224 + 424 + 24 + 2_024);
        let got: Vec<(&str, u64, u64, u64)> = s.causes.iter().map(|c| (c.name.as_str(), c.count, c.cost_micros, c.error_cost_micros)).collect();
        assert_eq!(
            got,
            [("Tasks from the lead", 1, 2_024, 0), ("Bash", 2, 212 + 24, 0), ("Your prompts", 1, 224, 0), ("Read", 1, 212, 212)]
        );
        let bash = &s.causes[1];
        assert_eq!((bash.model_calls, bash.errors, bash.avg_context), (1.5, 0, 101));
        assert_eq!(s.causes[3].errors, 1);

        assert_eq!(s.lanes[0].sonnet_cost_micros, Some(122 + 222 + 22));
        assert_eq!((s.lanes[1].cost_micros, s.lanes[1].sonnet_cost_micros, s.lanes[1].model_calls), (2_024, Some(1_022), 1));

        // The subagent on Opus would cost $0.001002 less on Sonnet: 37% of the session.
        let tip = s.tips.iter().find(|t| t.kind == TipKind::Model).expect("a model tip");
        assert_eq!((tip.cost_micros, tip.saving_micros), (2_024, Some(1_002)));
        assert_eq!(tip.title, "1 subagent on Opus 5.5 cost $0.00; on Sonnet 5.5 about $0.00");
        // One failed call is not enough for a tip.
        assert!(s.tips.iter().all(|t| t.kind != TipKind::Errors));

        assert_eq!((a.turns[0].cost_micros, a.turns[0].subagent_cost_micros), (672, 2_024));

        // Each event's cost: an answer its own call; a prompt or a tool its part of the call after it.
        let costs: Vec<Option<u64>> = a.lanes[0].events.iter().map(|e| e.cost_micros).collect();
        assert_eq!(costs, [Some(224), Some(224), Some(212), Some(212), Some(424), Some(24), Some(24)]);
        // And its tokens: m1 has 1 + 100 + 10 = 111; m2 has 121, half each (60.5, rounded up);
        // m3 has 101. An answer has none: its tokens are in its usage.
        let tokens: Vec<Option<u64>> = a.lanes[0].events.iter().map(|e| e.paid_tokens).collect();
        assert_eq!(tokens, [Some(111), None, Some(61), Some(61), None, Some(101), None]);
        // The subagent's task paid for its only call.
        let sub: Vec<Option<u64>> = a.lanes[1].events.iter().map(|e| e.cost_micros).collect();
        assert_eq!(sub, [Some(2_024), Some(2_024)]);
    }

    #[test]
    fn many_calls_and_failures_get_tips() {
        let commands = ["cd /p && sed -n 1p a.md", "grep -n x a.md", "cat a.md"];
        let mut lines = vec![prompt("00:00", "go")];
        for i in 0..12 {
            let t = format!("00:{:02}", i * 2 + 1);
            let r = format!("00:{:02}", i * 2 + 2);
            let call = json!({"type": "tool_use", "id": format!("t{i}"), "name": "Bash", "input": {"command": commands[i % 3], "description": format!("step {i}")}});
            lines.push(answer(&t, &format!("m{i}"), 50_000, 0, 100, json!([call])));
            let out = match i {
                0..3 => format!("This session is isolated in the worktree /p/wt, but this command runs a variable {i}. Refusing to run it."),
                3 => "Exit code 1 sed: a.md: No such file or directory".to_string(),
                _ => "out".to_string(),
            };
            lines.push(result(&r, &format!("t{i}"), &out, i < 4));
        }
        lines.push(answer("00:30", "end", 50_000, 0, 100, json!([])));
        let a = build("s", lane(LaneReader::main(), &lines), vec![]);
        let kinds: Vec<TipKind> = a.spend.tips.iter().map(|t| t.kind).collect();
        assert!(kinds.contains(&TipKind::ManyCalls), "{kinds:?}");
        assert!(kinds.contains(&TipKind::Errors), "{kinds:?}");

        // Each call after one Bash result costs 4 + 50,000×0.2 + 100×20 = 12,004.
        let groups: Vec<(&str, u64, u64, u64)> =
            a.spend.commands.iter().map(|c| (c.group.as_str(), c.calls, c.errors, c.cost_micros)).collect();
        assert_eq!(groups, [("cat", 4, 1, 48_016), ("grep", 4, 1, 48_016), ("sed", 4, 2, 48_016)]);
        assert_eq!(a.spend.commands[2].example.as_deref(), Some("step 0"));
        // Each call of a group, with its event: prompt, then answer and tool for each step.
        let sed: Vec<(&str, usize, u64)> = a.spend.commands[2].items.iter().map(|c| (c.lane.as_str(), c.event, c.cost_micros)).collect();
        assert_eq!(sed, [("main", 2, 12_004), ("main", 8, 12_004), ("main", 14, 12_004), ("main", 20, 12_004)]);
        assert_eq!(a.lanes[0].events[2].command.as_deref(), Some("cd /p && sed -n 1p a.md"));
        assert_eq!(a.lanes[0].events[1].command, None);
        let errors: Vec<(&str, u64, u64)> = a.spend.errors.iter().map(|e| (e.tool.as_str(), e.count, e.cost_micros)).collect();
        assert_eq!(errors, [("Bash", 3, 36_012), ("Bash", 1, 12_004)]);
        assert!(a.spend.errors[0].message.starts_with("This session is isolated in the worktree /p/wt"), "{}", a.spend.errors[0].message);

        let many = a.spend.tips.iter().find(|t| t.kind == TipKind::ManyCalls).unwrap();
        assert!(many.title.starts_with("Bash calls made the model run for 92% of the cost"), "{}", many.title);
        assert!(many.detail.contains("Most calls: cat 4, grep 4, sed 4."), "{}", many.detail);
        let errors = a.spend.tips.iter().find(|t| t.kind == TipKind::Errors).unwrap();
        assert_eq!(errors.title, "4 tool calls failed; the model calls after them cost $0.05");
        assert!(errors.detail.starts_with("Failed: Bash 4. Why:"), "{}", errors.detail);
        assert!(errors.detail.contains("3× Claude Code refused to run the command"), "{}", errors.detail);
        assert!(errors.detail.contains("1× A wrong path"), "{}", errors.detail);
        assert!(a.spend.errors[0].cause.as_deref().unwrap().starts_with("Claude Code refused to run the command"));
        assert!(a.spend.errors[1].cause.as_deref().unwrap().starts_with("A wrong path"));
    }

    #[test]
    fn known_errors_are_explained() {
        let why = |m: &str, g: Option<&str>| explain(m, g).map(|e| e.split(':').next().unwrap_or_default().to_string());
        assert_eq!(why("This session is isolated in the worktree /p/wt, but this command runs sed with", Some("sed")).as_deref(), Some("Claude Code refused to run the command"));
        assert_eq!(why("Exit code 2 Unexpected argument for build context <id>: .", Some("node build.js context")).as_deref(), Some("Wrong arguments for the program"));
        assert_eq!(why("Exit code 1 ls: logs/01-*/out: No such file or directory", Some("ls")).as_deref(), Some("A wrong path"));
        assert_eq!(why("Exit code 127 zsh: command not found: jq", Some("jq")).as_deref(), Some("A program that is not installed"));
        assert_eq!(why("Exit code 1 File \"<string>\", line 15 ''') ^ SyntaxError: unmatched ')'", None).as_deref(), Some("A script written inside the command has a syntax error"));
        assert_eq!(why("String to replace not found in file.", None).as_deref(), Some("Edit could not find the text to replace"));
        assert_eq!(why("File has not been read yet. Read it first before writing to it.", None).as_deref(), Some("Edit or Write before Read"));
        assert_eq!(why("Exit code 1", Some("grep")).as_deref(), Some("grep found no match"));
        assert_eq!(why("Exit code 1", Some("sed")), None);
        assert_eq!(why("Exit code 3 /tmp/p04.md is a file; pass the folder", None), None);
    }

    /// Claude Code's refusal text, as in Claude Code 2.1.317, for the worktree `/p/wt`.
    fn refused(what: &str) -> String {
        format!(
            "This session is isolated in the worktree /p/wt, but this command {what}, so what it runs cannot be shown not to be git. \
             Refusing to run it — a worktree-isolated session's git operations must target its own worktree. Run the plain command from /p/wt."
        )
    }

    #[test]
    fn worktree_refusals_are_told_apart() {
        let cases = [
            (
                "cd /p/wt/notes; for f in a b; do sed -n 1p $f.md; done",
                "runs sed with a value computed at runtime (the variable f) where an option may stand in a plain command",
                Some(Refusal::Loop),
            ),
            (
                "cd /p/wt/e && for f in a b; do cat $f.md | cut -c1-600; done",
                "runs rtk with a value computed at runtime (the variable f) inside a construct too complex to verify",
                Some(Refusal::Loop),
            ),
            ("ls *.md | while read -r name; do wc -l $name; done", "runs wc with a value computed at runtime (the variable name)", Some(Refusal::Loop)),
            ("R=/p/wt; sed -n 1p $R/a.md", "runs sed with a value computed at runtime (the variable R) where an option may stand", Some(Refusal::Variable)),
            // The loop is there, but the variable that was refused is another one.
            ("E=errors; for f in a b; do echo $f; done; grep -l x $E/*.md", "runs grep with a value computed at runtime (the variable E)", Some(Refusal::Variable)),
            (
                "S=\"node /p/wt/s.js\"; $S check .",
                "runs a command whose name is computed at runtime inside a construct too complex to verify",
                Some(Refusal::Variable),
            ),
            (
                "sed -n '/^## Text/,$p' a.md | node /p/wt/check.js lint -",
                "feeds node a descriptor it names in a plain command, whose content is assembled at runtime and may be read as a program",
                Some(Refusal::Stdin),
            ),
            ("grep -n x a.md | xargs -I{} sh -c 'sed -n {}p a.md'", "runs sh from a find -exec or xargs slot in a plain command", Some(Refusal::Xargs)),
            ("W=$(wc -w a.md); cd /p/wt && git status", "names git in a form too complex to verify that it stays inside the worktree", Some(Refusal::Git)),
            ("T() { sed -n 1p a.md; }; T | wc -l", "is too complex to verify that it stays inside the worktree", Some(Refusal::Complex)),
            ("cat >> a.md <<'EOF'\nA long text.\nEOF", "is too complex to verify that it stays inside the worktree", Some(Refusal::Complex)),
            (
                "cd /p/wt; grep -n x logs/02-*/a.md | head",
                "runs rtk with a value computed at runtime (a glob pattern) inside a construct too complex to verify",
                Some(Refusal::Other),
            ),
            ("git -C /p/other status", "runs git on another folder", Some(Refusal::Other)),
        ];
        for (command, what, want) in cases {
            assert_eq!(refusal(command, &refused(what)), want, "{command}");
        }
        assert_eq!(refusal("grep -n x a.md", "Exit code 1"), None);
        assert_eq!(refusal("", ""), None);
        assert!(Refusal::Loop.cause().starts_with("Claude Code refused to run the command: a `for` loop over files"), "{}", Refusal::Loop.cause());
        assert!(Refusal::Loop.cause().ends_with("or put the loop in a script file and run the script."), "{}", Refusal::Loop.cause());
    }

    #[test]
    fn worktree_refusals_get_one_fix_for_each_kind() {
        let calls = [
            ("for f in a b; do sed -n 1p $f.md; done", refused("runs sed with a value computed at runtime (the variable f)"), true),
            ("for n in 1 2; do sed -n 1p c$n.md; done", refused("runs sed with a value computed at runtime (the variable n)"), true),
            ("sed -n 1p a.md | node /p/wt/check.js -", refused("feeds node a descriptor it names in a plain command"), true),
            ("R=/p/wt; sed -n 1p $R/a.md", refused("runs sed with a value computed at runtime (the variable R)"), true),
            ("node /p/wt/check.js /p/wt/a.md", "Exit code 3 /p/wt/a.md is a file; pass the folder".to_string(), true),
            ("ls", "a.md".to_string(), false),
        ];
        let mut lines = vec![prompt("00:00", "go")];
        for (i, (command, out, error)) in calls.iter().enumerate() {
            let call = json!({"type": "tool_use", "id": format!("t{i}"), "name": "Bash", "input": {"command": command, "description": format!("step {i}")}});
            lines.push(answer(&format!("00:{:02}", i * 2 + 1), &format!("m{i}"), 50_000, 0, 100, json!([call])));
            lines.push(result(&format!("00:{:02}", i * 2 + 2), &format!("t{i}"), out, *error));
        }
        lines.push(answer("00:30", "end", 50_000, 0, 100, json!([])));
        let a = build("s", lane(LaneReader::main(), &lines), vec![]);

        let kinds: Vec<Option<Refusal>> = a.lanes[0].events.iter().filter(|e| e.kind == EventKind::Tool).map(|e| e.refusal).collect();
        assert_eq!(kinds, [Some(Refusal::Loop), Some(Refusal::Loop), Some(Refusal::Stdin), Some(Refusal::Variable), None, None]);

        // The two loops with different variables are one group; each call after one Bash result costs 12,004.
        let groups: Vec<(Option<Refusal>, u64, u64)> = a.spend.errors.iter().map(|e| (e.refusal, e.count, e.cost_micros)).collect();
        assert_eq!(groups, [(Some(Refusal::Loop), 2, 24_008), (None, 1, 12_004), (Some(Refusal::Stdin), 1, 12_004), (Some(Refusal::Variable), 1, 12_004)]);
        assert_eq!(a.spend.errors[0].cause, Some(Refusal::Loop.cause()));
        assert_eq!(a.spend.errors[1].cause, None);

        let tip = a.spend.tips.iter().find(|t| t.kind == TipKind::Errors).expect("an error tip");
        assert_eq!(tip.title, "5 tool calls failed; the model calls after them cost $0.06");
        let want = format!(
            "Failed: Bash 5. Why: 4× Claude Code refused to run the command, because the session works in its own git worktree and \
             Claude Code could not show from the command's text that it does not run git outside it: 2× {}: {}; 1× {}: {}; 1× {}: {}. \
             Write these rules in the project's CLAUDE.md, so that every agent reads them before it writes a command. \
             1× \"Exit code 3 /p/wt/a.md is a file; pass the folder\". Each failed call costs one more model call to try again.",
            Refusal::Loop.label(),
            Refusal::Loop.fix(),
            Refusal::Stdin.label(),
            Refusal::Stdin.fix(),
            Refusal::Variable.label(),
            Refusal::Variable.fix()
        );
        assert_eq!(tip.detail, want);
    }

    #[test]
    fn a_rewritten_cache_and_a_big_result_get_tips() {
        let a = build(
            "s",
            lane(
                LaneReader::main(),
                &[
                    prompt("00:00", "go"),
                    answer("00:01", "m1", 0, 30_000, 10, json!([tool("t1", "Read", "/p/big.md")])),
                    result("00:02", "t1", &"x".repeat(200_000), false),
                    answer("00:03", "m2", 30_000, 50_000, 10, json!([])),
                    prompt("40:00", "more"),
                    // After a long pause: all 80K written again.
                    answer("40:01", "m3", 0, 80_000, 10, json!([])),
                    prompt("41:00", "more"),
                    answer("41:01", "m4", 80_000, 0, 10, json!([])),
                ],
            ),
            vec![],
        );
        let rewrite = a.spend.tips.iter().find(|t| t.kind == TipKind::CacheRewrites).expect("a rewrite tip");
        // 80,000 × (8 - 0.2) = 624,000.
        assert_eq!(rewrite.saving_micros, Some(624_000));
        assert!(rewrite.title.starts_with("1 time the whole context"), "{}", rewrite.title);
        let big = a.spend.tips.iter().find(|t| t.kind == TipKind::BigResults).expect("a big result tip");
        assert!(big.detail.contains("Read /p/big.md: "), "{}", big.detail);
        assert!(!big.detail.contains("Files in tool-results"), "{}", big.detail);
        assert!(big.detail.contains("read again by 2 later calls"), "{}", big.detail);
        // The tips are sorted by money.
        let money: Vec<u64> = a.spend.tips.iter().map(|t| t.saving_micros.unwrap_or(t.cost_micros)).collect();
        assert!(money.windows(2).all(|w| w[0] >= w[1]), "{money:?}");
    }

    #[test]
    fn model_names() {
        assert_eq!(model_name("claude-opus-5-5"), "Opus 5.5");
        assert_eq!(model_name("claude-fable-5-1"), "Fable 5.1");
        assert_eq!(model_name("claude-opus-4-5-20251101"), "Opus 4.5");
        assert_eq!(dollars(1_234_567), "$1.23");
        assert_eq!(short_path("/Users/x/p/notes/big.md"), "…/notes/big.md");
        assert_eq!(short_path("/p/a.md"), "/p/a.md");
        assert_eq!(short_path("…ng-agent/3e870c57/tool-results/b1.txt"), "…/tool-results/b1.txt");
        assert_eq!(short_path("List files in /tmp/a/b"), "List files in /tmp/a/b");
    }
}
