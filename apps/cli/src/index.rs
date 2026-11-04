//! Finds the transcript files and reads them through an index file, so each
//! run reads only the bytes appended since the last run.
//!
//! Index: `~/Library/Caches/ccop/index.json`. For each file it keeps the size
//! and inode it saw, the byte offset up to which it read whole lines, and the
//! `Transcript` state at that offset. A file that got shorter or has another
//! inode is read again from the start.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use anyhow::{Context, Result};
use ccop_core::{FileFacts, HourUsage, Session, Transcript};
use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};

/// Change it when `Entry` or `Transcript` changes meaning: an index of
/// another format is dropped and every file is read again.
const FORMAT: u32 = 3;

/// A session counts as active when a file of it changed this recently.
pub const ACTIVE_SECS: i64 = 120;

#[derive(Serialize, Deserialize, Default)]
struct IndexFile {
    format: u32,
    files: HashMap<String, Entry>,
}

#[derive(Serialize, Deserialize, Clone)]
struct Entry {
    size: u64,
    inode: u64,
    modified_ns: i64,
    /// Bytes read so far; always the end of a whole line.
    offset: u64,
    transcript: Transcript,
}

/// Where the transcripts are and where the index goes.
pub struct Places {
    pub projects: PathBuf,
    pub cache: PathBuf,
}

impl Places {
    /// `CCOP_PROJECTS_DIR`, else `$CLAUDE_CONFIG_DIR/projects`, else
    /// `~/.claude/projects`. Index: `CCOP_CACHE_DIR`, else `~/Library/Caches/ccop`.
    pub fn from_env() -> Result<Places> {
        let home = std::env::var_os("HOME").map(PathBuf::from).context("HOME is not set")?;
        let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from);
        let projects = var("CCOP_PROJECTS_DIR")
            .or_else(|| var("CLAUDE_CONFIG_DIR").map(|d| d.join("projects")))
            .unwrap_or_else(|| home.join(".claude/projects"));
        let cache = var("CCOP_CACHE_DIR").unwrap_or_else(|| home.join("Library/Caches/ccop"));
        Ok(Places { projects, cache })
    }
}

/// One transcript file found on disk.
struct Found {
    path: PathBuf,
    key: String,
    /// The folder's name in `projects`.
    folder: String,
    session_id: String,
    subagent: bool,
    size: u64,
    inode: u64,
    modified_ns: i64,
}

pub struct ScanResult {
    pub sessions: Vec<Session>,
    /// Tokens and cost of every file (subagents too) by hour: Unix time / 3600.
    pub hours: std::collections::BTreeMap<i64, HourUsage>,
    pub files: usize,
    /// Bytes read in this run.
    pub bytes_read: u64,
}

pub fn scan(places: &Places, now: DateTime<Utc>) -> Result<ScanResult> {
    let found = find(&places.projects)?;
    let index_path = places.cache.join("index.json");
    let mut index = load(&index_path);
    let before = index.files.len();

    // What to read, and from where.
    let mut work: Vec<(usize, Entry)> = Vec::new();
    for (i, f) in found.iter().enumerate() {
        match index.files.get(&f.key) {
            Some(e) if e.inode == f.inode && e.size == f.size && e.modified_ns == f.modified_ns => {}
            Some(e) if e.inode == f.inode && f.size >= e.offset => work.push((i, e.clone())),
            _ => work.push((i, Entry { size: 0, inode: f.inode, modified_ns: 0, offset: 0, transcript: Transcript::default() })),
        }
    }
    let bytes_read = AtomicUsize::new(0);
    let done = Mutex::new(Vec::with_capacity(work.len()));
    let next = AtomicUsize::new(0);
    let workers = std::thread::available_parallelism().map_or(4, |n| n.get()).min(8);
    std::thread::scope(|s| {
        for _ in 0..workers {
            s.spawn(|| {
                loop {
                    let n = next.fetch_add(1, Ordering::Relaxed);
                    let Some((i, entry)) = work.get(n) else { break };
                    let f = &found[*i];
                    let mut entry = entry.clone();
                    // A fork found to be one only now, because its meta file
                    // came after its first lines, is read again from the start.
                    if f.subagent
                        && !entry.transcript.reads_a_fork()
                        && let Some(call) = crate::anatomy::lane_meta(&f.path).fork_call()
                    {
                        entry.transcript = Transcript::for_fork(call);
                        entry.offset = 0;
                    }
                    match read_from(&f.path, entry.offset, &mut entry.transcript) {
                        Ok(end) => {
                            bytes_read.fetch_add((end - entry.offset) as usize, Ordering::Relaxed);
                            entry.offset = end;
                            entry.size = f.size;
                            entry.inode = f.inode;
                            entry.modified_ns = f.modified_ns;
                            done.lock().unwrap().push((f.key.clone(), entry));
                        }
                        // Gone or unreadable: leave it out this time.
                        Err(_) => continue,
                    }
                }
            });
        }
    });
    let done = done.into_inner().unwrap();
    let changed = !done.is_empty();
    for (key, entry) in done {
        index.files.insert(key, entry);
    }
    let keys: std::collections::HashSet<&str> = found.iter().map(|f| f.key.as_str()).collect();
    index.files.retain(|k, _| keys.contains(k.as_str()));
    if changed || index.files.len() != before {
        save(&index_path, &index)?;
    }

    // Sessions: each main file with the subagent files of the same id.
    let mut subs: HashMap<(&str, &str), Vec<FileFacts>> = HashMap::new();
    for f in found.iter().filter(|f| f.subagent) {
        if let Some(e) = index.files.get(&f.key) {
            subs.entry((&f.folder, &f.session_id)).or_default().push(facts(f, e));
        }
    }
    let mut sessions: Vec<Session> = found
        .iter()
        .filter(|f| !f.subagent)
        .filter_map(|f| {
            let e = index.files.get(&f.key)?;
            let sub = subs.get(&(f.folder.as_str(), f.session_id.as_str())).map(Vec::as_slice).unwrap_or(&[]);
            Some(Session::build(&f.session_id, &f.folder, &facts(f, e), sub, now, ACTIVE_SECS))
        })
        .collect();
    sessions.sort_by(|a, b| last_activity(b).cmp(&last_activity(a)).then(a.id.cmp(&b.id)));
    let mut hours: std::collections::BTreeMap<i64, HourUsage> = std::collections::BTreeMap::new();
    for e in index.files.values() {
        for (h, u) in &e.transcript.hours {
            hours.entry(*h).or_default().add(u);
        }
    }
    Ok(ScanResult { sessions, hours, files: found.len(), bytes_read: bytes_read.into_inner() as u64 })
}

/// When the session last did something: its newest record, or its file's time.
pub fn last_activity(s: &Session) -> DateTime<Utc> {
    s.updated_at.unwrap_or(s.modified_at)
}

fn facts<'a>(f: &'a Found, e: &'a Entry) -> FileFacts<'a> {
    FileFacts {
        path: &f.key,
        transcript: &e.transcript,
        size: f.size,
        modified_at: Utc.timestamp_nanos(f.modified_ns),
    }
}

/// `<projects>/<folder>/<id>.jsonl` and `<projects>/<folder>/<id>/subagents/*.jsonl`.
fn find(projects: &Path) -> Result<Vec<Found>> {
    let mut out = Vec::new();
    let folders = match fs::read_dir(projects) {
        Ok(d) => d,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
        Err(e) => return Err(e).with_context(|| format!("cannot read {}", projects.display())),
    };
    for folder in folders.flatten() {
        if !folder.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }
        let folder_name = folder.file_name().to_string_lossy().into_owned();
        let Ok(items) = fs::read_dir(folder.path()) else { continue };
        for item in items.flatten() {
            let path = item.path();
            let name = item.file_name().to_string_lossy().into_owned();
            let Ok(kind) = item.file_type() else { continue };
            if kind.is_file() {
                if let Some(id) = name.strip_suffix(".jsonl") {
                    push(&mut out, path, &folder_name, id, false);
                }
            } else if kind.is_dir() {
                let Ok(agents) = fs::read_dir(path.join("subagents")) else { continue };
                for agent in agents.flatten() {
                    if agent.file_name().to_string_lossy().ends_with(".jsonl") {
                        push(&mut out, agent.path(), &folder_name, &name, true);
                    }
                }
            }
        }
    }
    Ok(out)
}

fn push(out: &mut Vec<Found>, path: PathBuf, folder: &str, id: &str, subagent: bool) {
    let Ok(meta) = fs::metadata(&path) else { return };
    if !meta.is_file() {
        return;
    }
    out.push(Found {
        key: path.to_string_lossy().into_owned(),
        path,
        folder: folder.to_string(),
        session_id: id.to_string(),
        subagent,
        size: meta.len(),
        inode: meta.ino(),
        modified_ns: meta.mtime() * 1_000_000_000 + meta.mtime_nsec(),
    });
}

/// Feeds the whole lines after `offset` and returns the offset after the
/// last whole line. A line still being written (no newline yet) waits for
/// the next run.
fn read_from(path: &Path, offset: u64, t: &mut Transcript) -> std::io::Result<u64> {
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut reader = BufReader::with_capacity(1 << 20, file);
    let mut end = offset;
    let mut line = Vec::new();
    loop {
        line.clear();
        let n = reader.read_until(b'\n', &mut line)?;
        if n == 0 || line.last() != Some(&b'\n') {
            break;
        }
        end += n as u64;
        match std::str::from_utf8(&line) {
            Ok(s) => t.feed(s),
            Err(_) => t.feed(&String::from_utf8_lossy(&line)),
        }
    }
    Ok(end)
}

fn load(path: &Path) -> IndexFile {
    let Ok(bytes) = fs::read(path) else { return IndexFile { format: FORMAT, ..Default::default() } };
    match serde_json::from_slice::<IndexFile>(&bytes) {
        Ok(i) if i.format == FORMAT => i,
        _ => IndexFile { format: FORMAT, ..Default::default() },
    }
}

/// Writes a temp file and renames it, so a reader never sees half a file.
fn save(path: &Path, index: &IndexFile) -> Result<()> {
    let dir = path.parent().context("index path has no folder")?;
    fs::create_dir_all(dir).with_context(|| format!("cannot create {}", dir.display()))?;
    let tmp = dir.join(format!(".index.{}.tmp", std::process::id()));
    fs::write(&tmp, serde_json::to_vec(index)?).with_context(|| format!("cannot write {}", tmp.display()))?;
    fs::rename(&tmp, path).with_context(|| format!("cannot write {}", path.display()))?;
    Ok(())
}
