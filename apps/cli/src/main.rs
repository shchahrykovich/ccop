//! `ccop`: lists Claude Code sessions and their token usage. The menu bar app
//! runs `ccop sessions --json`.

mod anatomy;
mod help_page;
mod index;
mod report;

use std::collections::BTreeMap;
use std::process::ExitCode;

use anyhow::{Result, bail};
use ccop_core::rollup::{By, What};
use ccop_core::{Session, Usage, short};
use chrono::{DateTime, Duration, Local, Utc};
use clap::{Parser, Subcommand};
use serde::Serialize;

use index::{Places, last_activity};

#[derive(Parser)]
#[command(
    name = "ccop",
    version,
    about = "Lists Claude Code sessions and their token usage",
    after_help = "An agent should run `ccop guide` first: it says which short reports to read."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
    /// Say on stderr how many files there are and how much this run read.
    #[arg(long, global = true)]
    verbose: bool,
}

#[derive(Subcommand)]
enum Command {
    /// Sessions, the newest first.
    Sessions {
        #[command(flatten)]
        filter: Filter,
        /// At most this many sessions.
        #[arg(long)]
        limit: Option<usize>,
        /// Print JSON (what the menu bar app reads).
        #[arg(long)]
        json: bool,
    },
    /// One session. ID can be the start of a session id.
    Show {
        id: String,
        #[arg(long)]
        json: bool,
    },
    /// Sessions and tokens by project folder, the most tokens first.
    Projects {
        #[command(flatten)]
        filter: Filter,
        #[arg(long)]
        json: bool,
    },
    /// Tokens and API-equivalent cost by day (or by hour with --json), all
    /// sessions and subagents together. The menu bar app reads the JSON.
    Usage {
        /// How many days back, today included.
        #[arg(long, default_value_t = 14)]
        days: i64,
        /// Print the hourly buckets as JSON.
        #[arg(long)]
        json: bool,
    },
    /// A short report: cost, main causes, commands, subagents, turns, tips. One
    /// session with ID (or the start of it), else all sessions of a period (7
    /// days unless --since says otherwise). A good first command for an agent.
    Brief {
        id: Option<String>,
        #[command(flatten)]
        filter: Filter,
        #[arg(long)]
        json: bool,
    },
    /// A list, the most cost first: commands, causes, agents, sessions, turns,
    /// errors, projects or tips. All sessions of a period (7 days unless
    /// --since says otherwise), or one with --session.
    Top {
        #[arg(value_parser = What::parse)]
        what: What,
        /// Only this session. ID can be the start of a session id.
        #[arg(long)]
        session: Option<String>,
        #[command(flatten)]
        filter: Filter,
        /// `cost` or `time`.
        #[arg(long, value_parser = By::parse, default_value = "cost")]
        by: By,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        #[arg(long)]
        json: bool,
    },
    /// The costliest calls behind one cause of a session: a tool (`Bash`), a
    /// program (`sed`), `prompts`, `tasks`, `compaction` or `other`.
    Cause {
        id: String,
        name: String,
        /// `cost` or `time`.
        #[arg(long, value_parser = By::parse, default_value = "cost")]
        by: By,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        #[arg(long)]
        json: bool,
    },
    /// Where the clock went in one session: model, tools, subagents, waiting;
    /// and the slowest calls and turns.
    Time {
        id: String,
        #[arg(long)]
        json: bool,
    },
    /// Print the instructions for agents.
    Guide,
    /// Print the help page as HTML (used by the app build).
    #[command(hide = true)]
    HelpPage,
    /// What one session did, and when: turns, model calls, tool calls and
    /// subagents. ID can be the start of a session id. Long: an agent should
    /// read `brief` first.
    Anatomy {
        id: String,
        /// Print JSON (what the app reads). A long session gives megabytes.
        #[arg(long)]
        json: bool,
    },
    /// The full texts of one lane: prompts, answers, tool inputs and the
    /// start of each tool output. The tokens are in `anatomy --json`, at the
    /// same event index. The app's Chat tab reads it.
    Chat {
        id: String,
        /// `main`, or a subagent's id (`Lane.id` in the anatomy).
        #[arg(long, default_value = "main")]
        lane: String,
        #[arg(long)]
        json: bool,
    },
    /// One tool call in full: its input and its whole output.
    Call {
        id: String,
        /// The call's `tool_use_id` (in `cause` or `anatomy --json`).
        tool_use_id: String,
        /// Cut the output and each long text of the input at this size. An
        /// output can be large: an agent should always give this.
        #[arg(long)]
        max_bytes: Option<usize>,
        #[arg(long)]
        json: bool,
    },
}

#[derive(clap::Args)]
struct Filter {
    /// Only sessions active in this period: 30m, 24h, 7d, 2w.
    #[arg(long, value_parser = parse_period)]
    since: Option<Duration>,
    /// Only sessions whose project folder contains this text.
    #[arg(long)]
    project: Option<String>,
    /// Only sessions whose title or prompts contain this text (any case).
    #[arg(long)]
    search: Option<String>,
    /// Only sessions with a file that changed in the last 2 minutes.
    #[arg(long)]
    active: bool,
}

impl Filter {
    fn is_empty(&self) -> bool {
        self.since.is_none() && self.project.is_none() && self.search.is_none() && !self.active
    }

    fn keep(&self, s: &Session, now: DateTime<Utc>) -> bool {
        if let Some(p) = self.since
            && last_activity(s) < now - p
        {
            return false;
        }
        if let Some(p) = &self.project
            && !s.project_dir.contains(p.as_str())
        {
            return false;
        }
        if let Some(q) = &self.search {
            let q = q.to_lowercase();
            let hit = [Some(&s.title), s.first_prompt.as_ref(), s.last_prompt.as_ref(), Some(&s.id)]
                .into_iter()
                .flatten()
                .any(|t| t.to_lowercase().contains(&q));
            if !hit {
                return false;
            }
        }
        !self.active || s.active
    }
}

/// `30m`, `24h`, `7d`, `2w`.
fn parse_period(text: &str) -> Result<Duration, String> {
    let (n, unit) = text.split_at(text.find(|c: char| !c.is_ascii_digit()).unwrap_or(text.len()));
    let n: i64 = n.parse().map_err(|_| format!("{text:?} is not a period such as 30m, 24h, 7d or 2w"))?;
    match unit {
        "m" => Ok(Duration::minutes(n)),
        "h" => Ok(Duration::hours(n)),
        "d" => Ok(Duration::days(n)),
        "w" => Ok(Duration::weeks(n)),
        _ => Err(format!("{text:?} is not a period such as 30m, 24h, 7d or 2w")),
    }
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ccop: {e:#}");
            ExitCode::FAILURE
        }
    }
}

/// What a report covers: one session, or those of the filter (with no
/// period: the last 7 days, so a report does not read every transcript).
fn chosen<'a>(sessions: &'a [Session], id: Option<&str>, mut filter: Filter, now: DateTime<Utc>) -> Result<Vec<&'a Session>> {
    if let Some(id) = id {
        if !filter.is_empty() {
            bail!("give one session or a filter (--since, --project, --search, --active), not both");
        }
        return Ok(vec![find(sessions, id)?]);
    }
    filter.since = filter.since.or(Some(Duration::days(7)));
    Ok(sessions.iter().filter(|s| filter.keep(s, now)).collect())
}

fn run(cli: Cli) -> Result<()> {
    // These two need no transcripts.
    match &cli.command {
        Command::Guide => {
            print!("{}", ccop_core::help::guide());
            return Ok(());
        }
        Command::HelpPage => {
            print!("{}", help_page::render()?);
            return Ok(());
        }
        _ => {}
    }
    let now = Utc::now();
    let places = Places::from_env()?;
    let scan = index::scan(&places, now)?;
    if cli.verbose {
        eprintln!(
            "ccop: {} files in {}, read {:.1} MB, {} ms",
            scan.files,
            places.projects.display(),
            scan.bytes_read as f64 / 1e6,
            (Utc::now() - now).num_milliseconds()
        );
    }
    match cli.command {
        Command::Sessions { filter, limit, json } => {
            let list: Vec<&Session> = scan.sessions.iter().filter(|s| filter.keep(s, now)).take(limit.unwrap_or(usize::MAX)).collect();
            if json {
                println!("{}", serde_json::to_string(&list)?);
            } else {
                print_sessions(&list);
            }
        }
        Command::Usage { days, json } => {
            let since = (now - Duration::days(days.max(1))).timestamp().div_euclid(3600);
            let hours: Vec<HourOut> = scan
                .hours
                .range(since..)
                .filter(|(_, u)| u.usage.requests > 0)
                .map(|(h, u)| HourOut {
                    start: DateTime::from_timestamp(h * 3600, 0).unwrap_or_default(),
                    usage: u.usage,
                    cost_micros: u.cost_micros,
                })
                .collect();
            if json {
                println!("{}", serde_json::to_string(&UsageOut { generated_at: now, hours })?);
            } else {
                print_usage(&hours);
            }
        }
        Command::Guide | Command::HelpPage => {}
        Command::Brief { id, filter, json } => {
            let list = chosen(&scan.sessions, id.as_deref(), filter, now)?;
            let (rollup, unreadable) = anatomy::rollup(&list);
            let brief = rollup.brief();
            if json {
                println!("{}", serde_json::to_string(&brief)?);
            } else {
                print!("{}", report::brief(&brief, id.is_some()));
                report::note_unreadable(unreadable);
            }
        }
        Command::Top { what, session, filter, by, limit, json } => {
            let list = chosen(&scan.sessions, session.as_deref(), filter, now)?;
            let (rollup, unreadable) = anatomy::rollup(&list);
            let mut rows = rollup.rows(what, by);
            let total = rows.len();
            rows.truncate(limit);
            if json {
                println!("{}", serde_json::to_string(&report::TopOut { what, by, sessions: rollup.sessions, cost_micros: rollup.cost_micros, total_rows: total, rows })?);
            } else {
                print!("{}", report::top(what, by, &rollup, &rows, total));
                report::note_unreadable(unreadable);
            }
        }
        Command::Cause { id, name, by, limit, json } => {
            let s = find(&scan.sessions, &id)?;
            let a = anatomy::read(&s.id, std::path::Path::new(&s.transcript))?;
            let cause = ccop_core::rollup::cause_report(&a, &name, by, limit)
                .map_err(|names| anyhow::anyhow!("this session has no cause or program {name:?}; it has: {}", names.join(", ")))?;
            if json {
                println!("{}", serde_json::to_string(&cause)?);
            } else {
                print!("{}", report::cause(&s.id, &cause));
            }
        }
        Command::Time { id, json } => {
            let s = find(&scan.sessions, &id)?;
            let a = anatomy::read(&s.id, std::path::Path::new(&s.transcript))?;
            let timing = ccop_core::timing::analyze(&a);
            if json {
                println!("{}", serde_json::to_string(&timing)?);
            } else {
                print!("{}", report::time(&s.title, &timing));
            }
        }
        Command::Anatomy { id, json } => {
            let s = find(&scan.sessions, &id)?;
            let a = anatomy::read(&s.id, std::path::Path::new(&s.transcript))?;
            if json {
                println!("{}", serde_json::to_string(&a)?);
            } else {
                print_anatomy(s, &a);
            }
        }
        Command::Chat { id, lane, json } => {
            let s = find(&scan.sessions, &id)?;
            let chat = anatomy::chat(std::path::Path::new(&s.transcript), &lane)?;
            if json {
                println!("{}", serde_json::to_string(&chat)?);
            } else {
                for t in &chat.texts {
                    if let Some(text) = &t.text {
                        println!("[{}] {text}\n", t.event);
                    }
                    if let Some(input) = &t.input {
                        println!("[{}] input: {input}", t.event);
                    }
                    if let Some(out) = &t.output {
                        println!("[{}] output: {}{}\n", t.event, out, if t.output_truncated { "…" } else { "" });
                    }
                }
            }
        }
        Command::Call { id, tool_use_id, max_bytes, json } => {
            let s = find(&scan.sessions, &id)?;
            let mut call = anatomy::call(std::path::Path::new(&s.transcript), &tool_use_id)?;
            if let Some(max) = max_bytes {
                call.limit(max);
            }
            if json {
                println!("{}", serde_json::to_string(&call)?);
            } else {
                println!("{} {}", call.tool.as_deref().unwrap_or("tool"), call.tool_use_id);
                println!("input: {}", serde_json::to_string_pretty(&call.input)?);
                println!("output ({} bytes{}):", call.output_bytes, if call.is_error { ", error" } else { "" });
                println!("{}", call.output.as_deref().unwrap_or("(no result yet)"));
                if call.output_truncated {
                    println!("(cut: this is the start of the output)");
                }
            }
        }
        Command::Show { id, json } => {
            let s = find(&scan.sessions, &id)?;
            if json {
                println!("{}", serde_json::to_string_pretty(s)?);
            } else {
                print_session(s);
            }
        }
        Command::Projects { filter, json } => {
            let projects = by_project(scan.sessions.iter().filter(|s| filter.keep(s, now)));
            if json {
                println!("{}", serde_json::to_string(&projects)?);
            } else {
                print_projects(&projects);
            }
        }
    }
    Ok(())
}

/// `ccop usage --json`: read by the app (apps/menubar/Sources/CCOPKit/Plan.swift).
#[derive(Serialize)]
struct UsageOut {
    generated_at: DateTime<Utc>,
    /// Hours with at least one call, oldest first.
    hours: Vec<HourOut>,
}

#[derive(Serialize)]
struct HourOut {
    start: DateTime<Utc>,
    usage: Usage,
    cost_micros: u64,
}

fn dollars(micros: u64) -> String {
    format!("${:.2}", micros as f64 / 1e6)
}

/// One line per local day.
fn print_usage(hours: &[HourOut]) {
    let mut days: BTreeMap<String, (Usage, u64)> = BTreeMap::new();
    for h in hours {
        let day = h.start.with_timezone(&Local).format("%Y-%m-%d %a").to_string();
        let d = days.entry(day).or_default();
        d.0 += h.usage;
        d.1 += h.cost_micros;
    }
    println!("{:<14}  {:>7}  {:>8}  {:>6}  {:>10}", "DAY", "TOKENS", "OUTPUT", "CALLS", "API COST");
    for (day, (u, cost)) in &days {
        println!("{:<14}  {:>7}  {:>8}  {:>6}  {:>10}", day, short(u.total()), short(u.output_tokens), u.requests, dollars(*cost));
    }
    println!("API cost is what the calls would cost at API prices; it weights tokens, it is not a bill.");
}

/// The one session whose id starts with `id`.
fn find<'a>(sessions: &'a [Session], id: &str) -> Result<&'a Session> {
    let hits: Vec<&Session> = sessions.iter().filter(|s| s.id.starts_with(id)).collect();
    match hits.as_slice() {
        [s] => Ok(s),
        [] => bail!("no session id starts with {id:?}"),
        many => bail!("{} sessions start with {id:?}; give more of the id", many.len()),
    }
}

fn duration(ms: i64) -> String {
    let s = ms / 1000;
    match s {
        _ if ms < 1000 => format!("{ms}ms"),
        0..60 => format!("{s}s"),
        60..3600 => format!("{}m{:02}s", s / 60, s % 60),
        _ => format!("{}h{:02}m", s / 3600, (s % 3600) / 60),
    }
}

fn print_anatomy(s: &Session, a: &ccop_core::anatomy::Anatomy) {
    use ccop_core::anatomy::EventKind;
    println!("{}  ({})", s.title, s.id);
    if let (Some(start), Some(end)) = (a.started_at, a.ended_at) {
        println!("{} to {}, {}", local(start), local(end), duration((end - start).num_milliseconds()));
    }
    println!();
    println!("TURNS");
    for t in &a.turns {
        println!(
            "  #{:<3} {}  {:>7}  {:>6} main  {:>6} subagents  {:>3} calls  {:>3} tools  {}",
            t.index,
            t.start.with_timezone(&Local).format("%H:%M"),
            duration((t.end - t.start).num_milliseconds()),
            short(t.usage.total()),
            short(t.subagent_usage.total()),
            t.answers,
            t.tool_calls,
            cut(&t.prompt, 60)
        );
    }
    println!();
    println!("LANES");
    for l in &a.lanes {
        let span = match (l.started_at, l.ended_at) {
            (Some(s), Some(e)) => format!("{}  {:>7}", s.with_timezone(&Local).format("%H:%M"), duration((e - s).num_milliseconds())),
            _ => "-".into(),
        };
        println!(
            "  {:<40}  {}  {:>6}  {:>4} tools  {:>3} errors  {}",
            cut(&l.name, 40),
            span,
            short(l.usage.total()),
            l.tool_calls,
            l.errors,
            l.model.as_deref().unwrap_or("")
        );
    }
    println!();
    println!("TOOLS");
    for t in &a.tools {
        println!(
            "  {:<24}  {:>5} calls  {:>4} errors  {:>8} total  {:>8} returned",
            cut(&t.tool, 24),
            t.calls,
            t.errors,
            duration(t.total_ms as i64),
            short(t.result_bytes) + "B"
        );
    }
    let spend = &a.spend;
    println!();
    println!("WHAT MADE THE MODEL RUN  ({} API-equivalent)", ccop_core::spend::dollars(spend.cost_micros));
    for c in &spend.causes {
        println!(
            "  {:<24}  {:>8}  {:>4.0}%  {:>6.0} model calls  {:>6} avg context  {:>4} errors",
            cut(&c.name, 24),
            ccop_core::spend::dollars(c.cost_micros),
            c.cost_micros as f64 * 100.0 / spend.cost_micros.max(1) as f64,
            c.model_calls,
            short(c.avg_context),
            c.errors
        );
    }
    if !spend.commands.is_empty() {
        println!();
        println!("BASH COMMANDS");
        for g in &spend.commands {
            println!(
                "  {:<32}  {:>4} calls  {:>3} errors  {:>8}  {}",
                cut(&g.group, 32),
                g.calls,
                g.errors,
                ccop_core::spend::dollars(g.cost_micros),
                cut(g.example.as_deref().unwrap_or(""), 60)
            );
        }
    }
    if !spend.errors.is_empty() {
        println!();
        println!("ERRORS");
        for e in &spend.errors {
            println!("  {:>3}x  {:<8}  {:>8}  {}", e.count, cut(&e.tool, 8), ccop_core::spend::dollars(e.cost_micros), cut(&e.message, 110));
            if let Some(cause) = &e.cause {
                println!("        Why: {cause}");
            }
        }
    }
    if !spend.tips.is_empty() {
        println!();
        println!("WHAT TO CHANGE");
        for t in &spend.tips {
            let saving = t.saving_micros.map(|s| format!("  (save up to {})", ccop_core::spend::dollars(s))).unwrap_or_default();
            println!("  - {}{saving}", t.title);
            println!("    {}", t.detail);
        }
    }
    let slow = a
        .lanes
        .iter()
        .flat_map(|l| l.events.iter().map(move |e| (l, e)))
        .filter(|(_, e)| e.kind == EventKind::Tool)
        .max_by_key(|(_, e)| e.end - e.start);
    if let Some((l, e)) = slow {
        println!();
        println!(
            "Slowest tool call: {} {} in {}, {}",
            e.tool.as_deref().unwrap_or(""),
            duration((e.end - e.start).num_milliseconds()),
            l.name,
            cut(e.text.as_deref().unwrap_or(""), 60)
        );
    }
}

#[derive(Serialize)]
struct Project {
    project_dir: String,
    sessions: u64,
    usage: Usage,
    updated_at: DateTime<Utc>,
}

fn by_project<'a>(sessions: impl Iterator<Item = &'a Session>) -> Vec<Project> {
    let mut map: BTreeMap<&str, Project> = BTreeMap::new();
    for s in sessions {
        let p = map.entry(&s.project_dir).or_insert_with(|| Project {
            project_dir: s.project_dir.clone(),
            sessions: 0,
            usage: Usage::default(),
            updated_at: last_activity(s),
        });
        p.sessions += 1;
        p.usage += s.usage;
        p.updated_at = p.updated_at.max(last_activity(s));
    }
    let mut out: Vec<Project> = map.into_values().collect();
    out.sort_by(|a, b| b.usage.total().cmp(&a.usage.total()).then(a.project_dir.cmp(&b.project_dir)));
    out
}

fn local(t: DateTime<Utc>) -> String {
    t.with_timezone(&Local).format("%Y-%m-%d %H:%M").to_string()
}

fn cut(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        text.to_string()
    } else {
        let mut s: String = text.chars().take(width - 1).collect();
        s.push('…');
        s
    }
}

fn print_sessions(list: &[&Session]) {
    println!("  {:<16}  {:<20}  {:>7}  {:>6}  {:>7}  {:<8}  TITLE", "LAST ACTIVITY", "PROJECT", "TOKENS", "CACHE", "PROMPTS", "ID");
    let mut total = Usage::default();
    for s in list {
        total += s.usage;
        println!(
            "{} {:<16}  {:<20}  {:>7}  {:>5.0}%  {:>7}  {:<8}  {}",
            if s.active { "●" } else { " " },
            local(last_activity(s)),
            cut(s.project_name(), 20),
            short(s.usage.total()),
            s.usage.cache_hit_ratio() * 100.0,
            s.prompts,
            &s.id[..s.id.len().min(8)],
            cut(&s.title, 70),
        );
    }
    println!("{} sessions, {} tokens", list.len(), short(total.total()));
}

fn usage_lines(u: &Usage) -> String {
    format!(
        "input {}  cache write {}  cache read {}  output {}  ({} requests, {:.0}% of input from cache)",
        short(u.input_tokens),
        short(u.cache_write_tokens),
        short(u.cache_read_tokens),
        short(u.output_tokens),
        u.requests,
        u.cache_hit_ratio() * 100.0
    )
}

fn print_session(s: &Session) {
    println!("{}", s.title);
    println!("  id          {}{}", s.id, if s.active { "  (active)" } else { "" });
    println!("  project     {}", s.project_dir);
    if let Some(b) = &s.git_branch {
        println!("  branch      {b}");
    }
    if let Some(t) = s.started_at {
        println!("  started     {}", local(t));
    }
    println!("  last        {}", local(last_activity(s)));
    println!("  prompts     {}  subagents {}", s.prompts, s.subagents);
    println!("  tokens      {}  {}", short(s.usage.total()), usage_lines(&s.usage));
    if s.subagents > 0 {
        println!("  subagents   {}  {}", short(s.subagent_usage.total()), usage_lines(&s.subagent_usage));
    }
    for m in &s.models {
        println!("  {:<11} {}  {}", cut(&m.model, 11), short(m.usage.total()), usage_lines(&m.usage));
    }
    if let Some(p) = &s.first_prompt {
        println!("  first       {p}");
    }
    if let Some(p) = &s.last_prompt {
        println!("  last prompt {p}");
    }
    println!("  transcript  {}", s.transcript);
    println!("  resume      cd '{}' && claude --resume {}", s.project_dir.replace('\'', r"'\''"), s.id);
}

fn print_projects(list: &[Project]) {
    println!("{:<16}  {:>8}  {:>7}  {:>6}  PROJECT", "LAST ACTIVITY", "SESSIONS", "TOKENS", "CACHE");
    for p in list {
        println!(
            "{:<16}  {:>8}  {:>7}  {:>5.0}%  {}",
            local(p.updated_at),
            p.sessions,
            short(p.usage.total()),
            p.usage.cache_hit_ratio() * 100.0,
            p.project_dir
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn periods() {
        assert_eq!(parse_period("30m"), Ok(Duration::minutes(30)));
        assert_eq!(parse_period("7d"), Ok(Duration::days(7)));
        assert_eq!(parse_period("2w"), Ok(Duration::weeks(2)));
        assert!(parse_period("7").is_err());
        assert!(parse_period("d").is_err());
        assert!(parse_period("3y").is_err());
    }
}
