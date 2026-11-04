//! Reads one session's files into its anatomy: the main transcript and each
//! `<id>/subagents/agent-<agent id>.jsonl` with its `.meta.json`. Not
//! through the index: it needs every event, and reads one session only.

use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};

use anyhow::{Context, Result};
use ccop_core::anatomy::{self, Anatomy, LaneMeta, LaneReader};
use ccop_core::rollup::Rollup;

pub fn read(session_id: &str, transcript: &Path) -> Result<Anatomy> {
    let main = read_lane(transcript, LaneReader::main()).with_context(|| format!("cannot read {}", transcript.display()))?;
    let mut subagents = Vec::new();
    let dir = transcript.with_extension("").join("subagents");
    if let Ok(items) = fs::read_dir(&dir) {
        for item in items.flatten() {
            let name = item.file_name().to_string_lossy().into_owned();
            let Some(stem) = name.strip_suffix(".jsonl") else { continue };
            let agent_id = stem.strip_prefix("agent-").unwrap_or(stem);
            let meta: LaneMeta = fs::read(dir.join(format!("{stem}.meta.json")))
                .ok()
                .and_then(|b| serde_json::from_slice(&b).ok())
                .unwrap_or_default();
            // A subagent file that cannot be read is left out.
            if let Ok(lane) = read_lane(&item.path(), LaneReader::subagent(agent_id, meta)) {
                subagents.push(lane);
            }
        }
    }
    Ok(anatomy::build(session_id, main, subagents))
}

/// Reads many sessions on up to 8 threads and adds them up. A session that
/// cannot be read is counted in the second number.
pub fn rollup(sessions: &[&ccop_core::Session]) -> (Rollup, u64) {
    let next = AtomicUsize::new(0);
    let threads = sessions.len().clamp(1, 8);
    let parts: Vec<(Rollup, u64)> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..threads)
            .map(|_| {
                scope.spawn(|| {
                    let mut total = Rollup::default();
                    let mut unreadable = 0;
                    while let Some(s) = sessions.get(next.fetch_add(1, Ordering::Relaxed)) {
                        match read(&s.id, Path::new(&s.transcript)) {
                            Ok(a) => total.merge(Rollup::of(s, &a)),
                            Err(_) => unreadable += 1,
                        }
                    }
                    (total, unreadable)
                })
            })
            .collect();
        workers.into_iter().map(|w| w.join().unwrap_or_default()).collect()
    });
    let mut total = Rollup::default();
    let mut unreadable = 0;
    for (part, n) in parts {
        total.merge(part);
        unreadable += n;
    }
    (total, unreadable)
}

/// The file of one lane: `main`, or a subagent's id.
fn lane_file(transcript: &Path, lane: &str) -> std::path::PathBuf {
    if lane == "main" {
        transcript.to_path_buf()
    } else {
        transcript.with_extension("").join("subagents").join(format!("agent-{lane}.jsonl"))
    }
}

/// The main file first, then the subagents' files.
fn all_files(transcript: &Path) -> Vec<std::path::PathBuf> {
    let mut files = vec![transcript.to_path_buf()];
    if let Ok(items) = fs::read_dir(transcript.with_extension("").join("subagents")) {
        let mut subs: Vec<_> = items.flatten().map(|i| i.path()).filter(|p| p.extension().is_some_and(|e| e == "jsonl")).collect();
        subs.sort();
        files.extend(subs);
    }
    files
}

#[derive(serde::Serialize)]
pub struct ChatOut {
    pub lane: String,
    pub texts: Vec<anatomy::ChatText>,
}

/// The full texts of one lane's events; their tokens are in the anatomy.
pub fn chat(transcript: &Path, lane: &str) -> Result<ChatOut> {
    let path = lane_file(transcript, lane);
    let reader = if lane == "main" { LaneReader::main() } else { LaneReader::subagent(lane, LaneMeta::default()) };
    let mut reader = reader.with_chat();
    for_each_line(&path, |l| {
        reader.feed(l);
        true
    })
    .with_context(|| format!("cannot read {}", path.display()))?;
    Ok(ChatOut { lane: lane.to_string(), texts: reader.finish_with_chat().1 })
}

/// One tool call in full, from whichever file of the session has it.
pub fn call(transcript: &Path, tool_use_id: &str) -> Result<ccop_core::call::ToolCall> {
    for path in all_files(transcript) {
        let mut finder = ccop_core::call::CallFinder::new(tool_use_id);
        for_each_line(&path, |l| {
            finder.feed(l);
            !finder.done()
        })
        .with_context(|| format!("cannot read {}", path.display()))?;
        if let Some(call) = finder.finish() {
            return Ok(call);
        }
    }
    anyhow::bail!("no tool call {tool_use_id} in this session")
}

/// Calls `f` with each line until it returns false.
fn for_each_line(path: &Path, mut f: impl FnMut(&str) -> bool) -> Result<()> {
    let mut file = BufReader::with_capacity(1 << 20, File::open(path)?);
    let mut line = Vec::new();
    loop {
        line.clear();
        if file.read_until(b'\n', &mut line)? == 0 || !f(&String::from_utf8_lossy(&line)) {
            return Ok(());
        }
    }
}

fn read_lane(path: &Path, mut reader: LaneReader) -> Result<anatomy::Lane> {
    let mut file = BufReader::with_capacity(1 << 20, File::open(path)?);
    let mut line = Vec::new();
    loop {
        line.clear();
        if file.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        reader.feed(&String::from_utf8_lossy(&line));
    }
    Ok(reader.finish())
}
