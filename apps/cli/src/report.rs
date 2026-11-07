//! The text of the short reports for agents: `brief`, `top`, `cause`, `time`,
//! `context`.
//! Short on purpose: each byte goes into an agent's context. Every report
//! ends with the commands to go further.

use std::fmt::Write;

use ccop_core::context::Contents;
use ccop_core::rollup::{Brief, By, CauseReport, Rollup, Row, What};
use ccop_core::short;
use ccop_core::spend::dollars;
use ccop_core::timing::Timing;
use serde::Serialize;

use crate::{cut, duration};

/// `ccop top --json`.
#[derive(Serialize)]
pub struct TopOut {
    pub what: What,
    pub by: By,
    pub sessions: u64,
    pub cost_micros: u64,
    /// All rows there are; `rows` has at most the limit.
    pub total_rows: usize,
    pub rows: Vec<Row>,
}

pub fn note_unreadable(count: u64) {
    if count > 0 {
        println!("{count} sessions could not be read and are left out.");
    }
}

fn ms(value: u64) -> String {
    duration(value as i64)
}

fn id8(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}

/// `Bash  $76.90  48%  942 calls  87 errors  124K ctx`, with what is known.
fn line(out: &mut String, r: &Row, unit: &str, width: usize) {
    let mut text = format!("  {:<width$}  {:>8}  {:>3.0}%", cut(&r.name, width), dollars(r.cost_micros), r.percent);
    if r.count > 0 {
        let _ = write!(text, "  {} {unit}", r.count);
    }
    if r.sessions > 1 {
        let _ = write!(text, "  in {} sessions", r.sessions);
    }
    if r.errors > 0 {
        let _ = write!(text, "  {} err", r.errors);
    }
    if let Some(c) = r.avg_context.filter(|c| *c > 0) {
        let _ = write!(text, "  {} ctx", short(c));
    }
    if r.total_ms > 0 {
        let _ = write!(text, "  {}", ms(r.total_ms));
    }
    if let Some(s) = r.saving_micros {
        let _ = write!(text, "  save {}", dollars(s));
    }
    out.push_str(&text);
    out.push('\n');
}

fn section(out: &mut String, title: &str, rows: &[Row], unit: &str) {
    if rows.is_empty() {
        return;
    }
    let _ = writeln!(out, "{title}");
    for r in rows {
        line(out, r, unit, 36);
    }
}

/// A folder's last part: the rest of the path says little in a short report.
fn with_project_names(rows: &[Row]) -> Vec<Row> {
    rows.iter().map(|r| Row { name: project_name(&r.name).to_string(), sessions: 1, ..r.clone() }).collect()
}

/// The id goes first: an agent needs it for the next command.
fn with_session_ids(rows: &[Row]) -> Vec<Row> {
    rows.iter().map(|r| Row { name: format!("{} {}", r.id.as_deref().map(id8).unwrap_or(""), r.name), ..r.clone() }).collect()
}

fn totals_line(cost: u64, tokens: u64, model_calls: u64, tool_calls: u64, errors: u64, subagents: u64, wall: u64) -> String {
    format!(
        "{} API-equivalent, {} tokens, {model_calls} model calls, {tool_calls} tools, {errors} errors, {subagents} subagents, {}",
        dollars(cost),
        short(tokens),
        ms(wall)
    )
}

pub fn brief(b: &Brief, one: bool) -> String {
    let mut out = String::new();
    if let (Some(id), Some(title)) = (&b.session_id, &b.title) {
        let _ = writeln!(out, "{}  {}  {}", cut(title, 60), id8(id), b.project_dir.as_deref().map(project_name).unwrap_or(""));
    } else {
        let _ = writeln!(out, "{} sessions (whole sessions active in the period)", b.sessions);
    }
    let _ = writeln!(out, "{}", totals_line(b.cost_micros, b.tokens, b.model_calls, b.tool_calls, b.errors, b.subagents, b.wall_ms));
    section(&mut out, "WHAT MADE THE MODEL RUN", &b.causes, "calls");
    section(&mut out, "BASH PROGRAMS", &b.commands, "calls");
    section(&mut out, "SESSIONS", &with_session_ids(&b.top_sessions), "prompts");
    section(&mut out, "PROJECTS", &with_project_names(&b.projects), "sessions");
    section(&mut out, "SUBAGENTS", &b.agents, if b.sessions > 1 { "agents" } else { "tools" });
    if b.sessions <= 1 {
        section(&mut out, "TURNS", &b.turns, "tools");
    }
    if !b.tips.is_empty() {
        let _ = writeln!(out, "WHAT TO CHANGE");
        for t in &b.tips {
            let saving = t.saving_micros.map(|s| format!(" (save up to {})", dollars(s))).unwrap_or_default();
            let _ = writeln!(out, "  - {}{saving}", cut(&t.name, 100));
        }
    }
    let scope = match (&b.session_id, one) {
        (Some(id), true) => format!("--session {}", id8(id)),
        _ => "--since 7d".to_string(),
    };
    let _ = writeln!(out, "NEXT: ccop top commands|causes|agents|turns|errors|tips {scope} [--by time]");
    if let (Some(id), true) = (&b.session_id, one) {
        let _ = writeln!(out, "      ccop cause {0} NAME, ccop time {0}", id8(id));
    }
    out
}

fn project_name(dir: &str) -> &str {
    dir.rsplit('/').find(|p| !p.is_empty()).unwrap_or(dir)
}

fn top_unit(what: What, many: bool) -> &'static str {
    match what {
        What::Commands | What::Causes => "calls",
        What::Agents if many => "agents",
        What::Agents | What::Turns => "tools",
        What::Sessions => "prompts",
        What::Errors => "times",
        What::Projects => "sessions",
        What::Tips => "times",
    }
}

pub fn top(what: What, by: By, r: &Rollup, rows: &[Row], total: usize) -> String {
    let mut out = String::new();
    let order = match by {
        By::Cost => "most cost",
        By::Time => "most time",
    };
    let _ = writeln!(
        out,
        "{} of {total} rows, {order} first. {}, {} in all{}.",
        rows.len(),
        if r.sessions == 1 { "1 session".to_string() } else { format!("{} sessions", r.sessions) },
        dollars(r.cost_micros),
        if r.sessions == 1 { "" } else { " (whole sessions active in the period)" }
    );
    let many = r.sessions > 1;
    let rows: Vec<Row> = if what == What::Projects { with_project_names(rows) } else { rows.to_vec() };
    for row in &rows {
        line(&mut out, row, top_unit(what, many), 44);
        match what {
            What::Sessions => {
                if let Some(id) = &row.id {
                    let _ = writeln!(out, "      {} {}", id8(id), row.detail.as_deref().unwrap_or(""));
                }
            }
            What::Turns => {
                if let (Some(session), Some(id)) = (&row.session, &row.id) {
                    let _ = writeln!(out, "      {} turn {id}", id8(session));
                }
            }
            What::Agents if !many => {
                if let Some(id) = &row.id {
                    let _ = writeln!(out, "      lane {id}  {}", row.detail.as_deref().unwrap_or(""));
                }
            }
            What::Commands | What::Errors | What::Tips => {
                if let Some(d) = &row.detail {
                    let _ = writeln!(out, "      {}", cut(d, 300));
                }
            }
            _ => {}
        }
    }
    out
}

pub fn cause(session: &str, c: &CauseReport) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "{}: {} calls, {} errors, {} ({:.0}% of the session)", c.name, c.total_calls, c.errors, dollars(c.cost_micros), c.percent);
    for call in &c.calls {
        let bytes = call.result_bytes.map(|b| format!("{}B", short(b))).unwrap_or_default();
        let _ = writeln!(
            out,
            "  {:>8}  {:>7}  {:>6}  {}{}",
            dollars(call.cost_micros),
            ms(call.ms),
            bytes,
            if call.is_error { "ERROR " } else { "" },
            cut(call.text.as_deref().unwrap_or(""), 70)
        );
        let _ = writeln!(out, "      {} event {}{}", cut(&call.lane_name, 30), call.event, call.tool_use_id.as_deref().map(|u| format!("  {u}")).unwrap_or_default());
    }
    if c.calls.len() < c.total_calls {
        let _ = writeln!(out, "{} more: --limit", c.total_calls - c.calls.len());
    }
    let _ = writeln!(out, "NEXT: ccop call {} TOOL_USE_ID --max-bytes 4000", id8(session));
    out
}

pub fn time(title: &str, t: &Timing) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "{}  {}", cut(title, 60), id8(&t.session_id));
    let _ = writeln!(out, "CLOCK  {} (the parts add up to this)", ms(t.wall_ms));
    let wall = t.wall_ms.max(1) as f64;
    for (name, value) in [
        ("Main lane waits for the model", t.model_ms),
        ("Main lane waits for tools", t.tools_ms),
        ("Only subagents run", t.subagents_ms),
        ("Nothing runs: waits for a person", t.waiting_ms),
    ] {
        let _ = writeln!(out, "  {name:<34}  {:>7}  {:>3.0}%", ms(value), value as f64 * 100.0 / wall);
    }
    let w = &t.work;
    let _ = writeln!(
        out,
        "WORK in all lanes (parallel work counts more than once): {} model calls {}, {} tools {}, {} subagents",
        w.model_calls,
        ms(w.model_ms),
        w.tool_calls,
        ms(w.tool_ms),
        w.subagents
    );
    if !t.tools.is_empty() {
        let _ = writeln!(out, "TOOLS (per lane; calls sent together count once)");
        for tool in t.tools.iter().take(8) {
            let _ = writeln!(out, "  {:<24}  {:>7}  {} calls", cut(&tool.tool, 24), ms(tool.clock_ms), tool.calls);
        }
    }
    if !t.slowest.is_empty() {
        let _ = writeln!(out, "SLOWEST CALLS");
        for c in &t.slowest {
            let what = match c.output_tokens {
                Some(o) => format!("{} output tokens", short(o)),
                None => cut(c.text.as_deref().unwrap_or(""), 60),
            };
            let _ = writeln!(out, "  {:>7}  {:<10}  {what}", ms(c.ms), cut(&c.name, 10));
            let _ = writeln!(out, "      {} event {}{}", cut(&c.lane_name, 30), c.event, c.tool_use_id.as_deref().map(|u| format!("  {u}")).unwrap_or_default());
        }
    }
    if !t.turns.is_empty() {
        let _ = writeln!(out, "SLOWEST TURNS (with their subagents)");
        for turn in t.turns.iter().take(5) {
            let _ = writeln!(out, "  #{:<3} {:>7}  {} tools, {} subagents  {}", turn.index, ms(turn.ms), turn.tool_calls, turn.subagents, cut(&turn.prompt, 50));
        }
    }
    out
}

/// `ccop context`: `total_rows` is the number of rows before `--limit`.
pub fn context(session: &str, c: &Contents, total_rows: usize) -> String {
    let mut out = String::new();
    let lane = if c.lane == "main" { String::new() } else { format!(" lane {}", c.lane) };
    let _ = writeln!(out, "CONTEXT {}{lane} call {} of {}: {} tokens (exact; the rows are estimated)", id8(session), c.call, c.calls, short(c.total));
    let total = c.total.max(1) as f64;
    for r in &c.rows {
        let times = if r.events.len() > 1 { format!("{}x", r.events.len()) } else { String::new() };
        let part = r.part.strip_prefix("Tool: ").unwrap_or(&r.part);
        let _ = writeln!(out, "  {:>6}  {:>3.0}%  {:>4}  {:<14}  {}", short(r.tokens), r.tokens as f64 * 100.0 / total, times, cut(part, 14), cut(&r.label, 80));
    }
    if c.rows.len() < total_rows {
        let _ = writeln!(out, "{} more: --limit", total_rows - c.rows.len());
    }
    let _ = writeln!(out, "NEXT: ccop context {} --call N (another call), --each (each read on its own), ccop call {} TOOL_USE_ID --max-bytes 4000 (with --json)", id8(session), id8(session));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(name: &str) -> Row {
        Row {
            name: name.into(),
            id: None,
            session: None,
            cost_micros: 123_456_789,
            percent: 48.0,
            count: 1234,
            errors: 56,
            sessions: 1,
            total_ms: 3_600_000,
            avg_context: Some(124_000),
            saving_micros: None,
            detail: None,
        }
    }

    fn big_brief(sessions: u64) -> Brief {
        // Cyrillic: 2 bytes a character, so this is the longest a name can be.
        let long = "Очень длинное название ".repeat(10);
        let rows = |n: usize| -> Vec<Row> { (0..n).map(|_| row(&long)).collect() };
        Brief {
            session_id: (sessions == 1).then(|| "1ac057a1-0000-0000-0000-000000000000".to_string()),
            title: (sessions == 1).then(|| long.clone()),
            project_dir: (sessions == 1).then(|| "/made/up/project".to_string()),
            sessions,
            cost_micros: 161_660_000,
            tokens: 199_000_000,
            model_calls: 1300,
            tool_calls: 1500,
            errors: 87,
            subagents: 48,
            wall_ms: 12_000_000,
            causes: rows(5),
            commands: rows(5),
            agents: rows(3),
            turns: rows(3),
            top_sessions: if sessions > 1 { rows(3) } else { Vec::new() },
            projects: if sessions > 1 { rows(3) } else { Vec::new() },
            tips: (0..3).map(|_| Row { saving_micros: Some(47_000_000), ..row(&"A long tip title with many words ".repeat(5)) }).collect(),
        }
    }

    /// The reason `brief` exists: it fits in a small part of a context. This
    /// is the longest it can be: every name is full and in Cyrillic (2 bytes a
    /// character). Real ones are about 2 KB: 1.6 KB and 2.4 KB when checked.
    #[test]
    fn a_brief_stays_under_3500_bytes_at_its_longest() {
        for sessions in [1, 5] {
            let text = brief(&big_brief(sessions), sessions == 1);
            assert!(text.len() <= 3_500, "{sessions} sessions: {} bytes\n{text}", text.len());
        }
    }

    #[test]
    fn a_brief_of_one_session_says_how_to_go_further_in_that_session() {
        let text = brief(&big_brief(1), true);
        assert!(text.contains("--session 1ac057a1"), "{text}");
        assert!(text.contains("ccop cause 1ac057a1 NAME"), "{text}");
        assert!(text.contains("ccop time 1ac057a1"), "{text}");
    }
}
