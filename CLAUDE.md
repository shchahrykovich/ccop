# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ccop is a macOS menu bar app that shows all Claude Code sessions on this Mac and their token usage, to help reduce it. It is a Rust workspace (core library and CLI) with a Swift menu bar app.

## Commands

```
cargo test --workspace                                   # all Rust tests
cargo test -p ccop-core the_newest_line                  # one Rust test (name filter)
cargo clippy --workspace --all-targets                   # expected: no warnings
swift test --package-path apps/menubar                   # Swift tests
swift test --package-path apps/menubar --filter SessionListTests
scripts/build-app.sh                                     # build/CCOP.app, ad-hoc signed
scripts/install.sh --user --launch                       # build and install to ~/Applications
build/CCOP.app/Contents/MacOS/CCOP --show                # run with the popover open (for screenshots)
build/CCOP.app/Contents/MacOS/CCOP --window <id-prefix> anatomy   # open the window at a session (id prefix) and tab
cargo run -p ccop -- sessions --since 1d --verbose       # the CLI; --verbose prints files, MB read, ms
cargo run -p ccop -- anatomy <id-prefix>                 # turns, lanes, tools of one session (--json for the app)
cargo run -p ccop -- usage --days 7                      # tokens and API-equivalent cost per day (--json: per hour)
cargo run -p ccop -- chat <id-prefix> --lane main --json # full texts of one lane, by event index (the app's Chat tab)
cargo run -p ccop -- call <id-prefix> <tool_use_id>      # one tool call in full: input and whole output
build/CCOP.app/Contents/MacOS/CCOP --plan                # open the plan settings window at launch
UPDATE_EXAMPLES=1 cargo test -p ccop-core --test api_example   # rewrite api/anatomy.example.json after a type change
```

To screenshot the window while another app is in front, capture it by window number (`screencapture -l <number>`; get the number from `CGWindowListCopyWindowInfo` for owner `CCOP`) instead of bringing it to the front.

Use a separate index so a test run does not touch the app's: `CCOP_CACHE_DIR=<tmp dir> cargo run -p ccop -- sessions`.

## Architecture

```
~/.claude/projects/**/*.jsonl ──► ccop CLI (Rust) ──► ~/Library/Caches/ccop/index.json
                                     │
                                     ├─ ccop sessions --json ──► CCOP.app (Swift): popover + main window
~/.claude/projects/<f>/<id>.jsonl ──┐  │
  <id>/subagents/agent-*.jsonl      ├──┴─ ccop anatomy <id> --json ──► Anatomy and Context tabs (read on demand, no index)
  <id>/subagents/agent-*.meta.json ─┘
```

- `libs/core` (`ccop-core`): no file access. `transcript.rs` turns lines of one transcript file into a `Transcript` (title, folder, branch, prompts, times, tokens by model). `Transcript` is serializable so the CLI can save it and feed more lines later. `session.rs` joins a main transcript with its subagent files into a `Session`, the JSON type the app reads. `anatomy.rs`: `LaneReader` turns one file (main or one subagent) into a `Lane` of events (prompt, answer, tool, compact, error); `build` links each subagent to the `Agent` tool call that started it and splits the main lane into turns. `context.rs` splits each call's context size into parts (see below). `spend.rs` puts the API-equivalent cost of each model call on what made it run (the tool results before it, split evenly; a prompt; a subagent's task) and writes tips with a cost or a saving; it is the `spend` field of the anatomy JSON. A Bash call that Claude Code refused in a worktree session gets a `Refusal` kind (loop, stdin, variable, xargs, git, complex, other) from the refusal text and the command; the error tip gives a count and a fix for each kind.
- `apps/cli` (`ccop`): `index.rs` finds the files and keeps the index: per file the size, inode, mtime, the byte offset after the last whole line, and the `Transcript` state at that offset. A run reads only appended bytes; a file that got shorter or has a new inode is read from 0; a half-written last line waits for the next run. Files are read by up to 8 threads. Bump `FORMAT` in `index.rs` when `Transcript` or `Entry` changes meaning, so old indexes are dropped.
- `apps/menubar`: Swift package. `CCOPKit` has the Swift copy of `Session`, the CLI runner, filters, day sections, formatting and the resume command (all tested). `CCOP` is the AppKit app: no Dock icon (`LSUIElement`), left click opens the popover, right click shows Refresh and Quit. It runs the CLI every 30 s while the popover is open and every 2 min otherwise. The menu bar number is the tokens of sessions active today (whole-session totals, not only today's tokens).
- Chat tab (`ChatView.swift`): the messages of one lane as in the chat. The texts come from `ccop chat` (`LaneReader::with_chat`, keyed by event index); the tokens and `cost_micros` of each event come from the anatomy. `CallSheet` (`CallViews.swift`) shows one call in full via `ccop call`; the Spend tab's Bash table opens it from each program's list of calls (`CommandGroup.items`).
- The main window (`MainWindow.swift`): the session list beside Overview, Spend (`SpendView.swift`: tips, cost per prompt, per cause, per agent), Anatomy (`AnatomyView.swift`: Canvas timeline, turns, tools, subagents) and Context (`ContextView.swift`: Swift Charts stacked area). While it is open the activation policy is `.regular` (Dock icon); on close it goes back to `.accessory`. `TimeScale` (CCOPKit) shortens idle gaps over 2 min on the timeline.
- Plan and limits: `libs/core/src/pricing.rs` prices each call at API rates (model, 1-hour vs 5-minute cache writes, Haiku 5.5's long-prompt rate card) in micro-dollars; `Transcript.hours` keeps tokens and cost per Unix hour, so days and weeks can be cut at any reset time. `CCOPKit/Plan.swift`: `PlanSettings` (tier, a reset moment repeating every 7 days, the calibrated weekly limit), `Plan.status` (week, calendar days, daily share = limit / 7), `Plan.calibrate` (limit = cost since reset ÷ the /usage percent the user types). Anthropic publishes no limit numbers and Claude Code saves no /usage data on disk (checked 2026-11-02), so calibration is the only source. The menu bar shows `33%/87%`: today as a percent of today's allowance (colored green to red, red over 100%), then the week as a percent of the weekly limit (`Plan.menuLabel`). Update the price table when models or prices change (source: the claude-api skill's model table and `shared/model-migration.md`).
- The app finds the CLI at `CCOP_CLI`, then `CCOP.app/Contents/Helpers/ccop`, then `target/release/ccop` above the executable (for `swift run`). The CLI is in `Helpers`, not `MacOS`: `ccop` and `CCOP` are the same name on a case-insensitive file system.

### Changing the JSON

The `Session`, `Anatomy` and `ccop usage` JSON exist twice: Rust (`libs/core/src/session.rs`, `anatomy.rs`) and Swift (`apps/menubar/Sources/CCOPKit/Session.swift`, `Anatomy.swift`, `Plan.swift`; snake_case keys are converted, and a digit part is capitalized: `cache_write_1h_tokens` decodes into `cacheWrite1HTokens`). Update both. `api/sessions.example.json` is hand-written and checked to have exactly the Rust fields; `api/anatomy.example.json` is written by `libs/core/tests/api_example.rs` from the real code (`UPDATE_EXAMPLES=1`). `SessionContractTests` and `AnatomyContractTests` decode both in Swift.

### Context parts are estimated

A call's context size is exact (input + cache write + cache read). The split is not: `context.rs` gives the growth between two calls first to the previous answer's `output_tokens` ("Claude output"), then to the prompts and tool results between them by bytes; the first call is "Start"; after a compaction "Start" + "Compacted summary"; a shrink scales every part. Claude Code's `api-request` / `api-request-blob` / `api-request-shape` records look like they hold the exact request, but most message hashes have no blob in the file (answers and tool results are not stored as blobs), so the request cannot be rebuilt from them.

## Transcript format (checked 2026-11-02; not a stable public API)

- Main file `~/.claude/projects/<folder>/<session-id>.jsonl`; subagents in `<folder>/<session-id>/subagents/agent-*.jsonl`. `<folder>` is the cwd with every non-alphanumeric character replaced by `-`; many names start with `-`, so pass `--` to `ls`. `CLAUDE_CONFIG_DIR` moves `~/.claude`; `CCOP_PROJECTS_DIR` overrides the folder for ccop.
- Tokens are in `assistant` records at `.message.usage` (`input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`). One API answer is written as several lines (one per content block), each with the same `.message.id`, `requestId` and full usage: count it once. In 18,541 answers checked, the lines of one answer were always next to each other, which is what lets `Transcript` dedupe with only the last answer's key. Model `<synthetic>` costs nothing.
- Titles: `agent-name` (`agentName`, set by the user) wins over `ai-title` (`aiTitle`, newest wins), then the first prompt. `relocated` (`relocatedCwd`) moves the folder; `continued-in` (`continuedInSessionId`) links the next session. User records with `isMeta`, `isSidechain` or `isCompactSummary`, and tool results, are not prompts.
- Tool calls: `tool_use` blocks in answers (`id`, `name`, `input`); results: `tool_result` blocks in the next user record (`tool_use_id`, `is_error`, `content`), with `toolUseResult` beside. An `Agent` result has `toolUseResult.agentId`; background agents return at once (`status: async_launched`), so a subagent's start and end come from its own file. `agent-<id>.meta.json` has `agentType`, `description`, `toolUseId`. `system` records with `subtype: compact_boundary` have `compactMetadata` (`trigger`, `preTokens`, `postTokens`, `durationMs`); `subtype: api_error` is an API error.
- Size on this Mac: about 14 GB in 7,000+ files. A first scan takes about 3 s; a scan with the index about 50-80 ms. `sessions --json` for all sessions is about 8 MB, and the app decodes it in about 160 ms.
