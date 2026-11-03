# ccop

ccop is a macOS menu bar app. It shows all Claude Code sessions on your Mac and how many tokens each one used. The goal is to help you see where tokens go, so you can use fewer of them.

It reads the transcript files that Claude Code already writes to `~/.claude/projects/`. It sends nothing over the network.

## What it shows

| Place | What you see |
|---|---|
| Menu bar | Today as a percent of your daily share, and the week as a percent of your weekly limit, for example `33%/87%` |
| Popover | Sessions grouped by day, with title, folder, branch and tokens |
| Overview tab | Totals for one session, by model |
| Spend tab | Cost per prompt, per cause and per subagent, and tips with the cost or saving of each |
| Anatomy tab | A timeline of turns, model calls, tool calls and subagents |
| Context tab | How the context grew over the session, split into parts (estimated) |
| Chat tab | The messages of one session, with the tokens and cost of each |

Costs are "API-equivalent": what the same calls would cost at Anthropic API prices. Anthropic does not publish plan limits, so you set the weekly limit once from the `/usage` percent that Claude Code shows.

## Requirements

- macOS 14 or later
- Rust 1.97 (`rust-toolchain.toml` selects it if you use rustup)
- Swift 6 (Xcode 16 or the Command Line Tools)

## Install

Build the app and install it to `~/Applications`, then open it:

```
scripts/install.sh --user --launch
```

Without `--user` it installs to `/Applications`. The app is ad-hoc signed.

The app has no Dock icon. Left-click the menu bar item to open the popover. Right-click it for Refresh and Quit.

## Command line

The app uses a Rust CLI, `ccop`. You can also run it yourself:

```
cargo run -p ccop -- sessions --since 1d     # sessions, newest first
cargo run -p ccop -- projects                # tokens by project folder
cargo run -p ccop -- usage --days 7          # tokens and cost per day
cargo run -p ccop -- anatomy <id-prefix>     # turns, tools and subagents of one session
cargo run -p ccop -- chat <id-prefix>        # the texts of one session
cargo run -p ccop -- call <id-prefix> <tool_use_id>   # one tool call in full
```

`<id-prefix>` is the start of a session id. Every command takes `--json`.

The CLI keeps an index in `~/Library/Caches/ccop/index.json`. On each run it reads only the bytes added to each file since the last run, so a run with the index takes about 50-80 ms. Set `CCOP_CACHE_DIR` to use another index folder, and `CCOP_PROJECTS_DIR` to read transcripts from another folder.

## How it works

```
~/.claude/projects/**/*.jsonl ──► ccop CLI (Rust) ──► ~/Library/Caches/ccop/index.json
                                     │
                                     ├─ ccop sessions --json ──► CCOP.app (Swift): popover + main window
                                     └─ ccop anatomy <id> --json ──► Spend, Anatomy, Context tabs
```

| Folder | Content |
|---|---|
| `libs/core` | Rust library: parses transcripts, joins subagents, splits context, prices calls. No file access. |
| `apps/cli` | Rust CLI `ccop`: finds files, keeps the index, prints text or JSON |
| `apps/menubar` | Swift package: `CCOPKit` (types, tested) and `CCOP` (the AppKit app) |
| `api` | Example JSON for the `Session` and `Anatomy` types |
| `scripts` | Build and install scripts |

The Claude Code transcript format is not a stable public API. A new Claude Code version can change it.

## Development

```
cargo test --workspace
cargo clippy --workspace --all-targets
swift test --package-path apps/menubar
scripts/build-app.sh            # builds build/CCOP.app
```

`CLAUDE.md` has more detail on the architecture and the transcript format.

## License

MIT
