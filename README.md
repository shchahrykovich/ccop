# ccop

ccop is a macOS menu bar app. It shows all Claude Code sessions on your Mac and how many tokens each one used. The goal is to help you see where tokens go, so you can use fewer of them.

It reads the transcript files that Claude Code already writes to `~/.claude/projects/`. Your sessions never leave your Mac. The only network request is the update check to GitHub (see [Updates](#updates)).

## What it shows

| Place | What you see |
|---|---|
| Menu bar | Today as a percent of your daily share, and the week as a percent of your weekly limit, for example `33%/87%` |
| Popover | Sessions grouped by day, with title, folder, branch and tokens |
| Flagged list | The sessions you flagged, of any age: right-click a session and choose **Flag**, then choose **Flagged** beside the periods |
| Overview tab | Totals for one session, by model |
| Spend tab | Cost per prompt, per cause and per subagent, and tips with the cost or saving of each |
| Anatomy tab | A timeline of turns, model calls, tool calls and subagents |
| Context tab | How the context grew over the session, split into parts (estimated) |
| Chat tab | The messages of one session, with the tokens and cost of each |

Costs are "API-equivalent": what the same calls would cost at Anthropic API prices. Anthropic does not publish plan limits as numbers. ccop runs `claude -p /usage` when it starts and then every hour, and takes the weekly percent and the reset time from it. From that percent and the cost it measured, it works out the weekly limit in dollars and the share for today. If `claude` is not found, you can type the numbers in Plan settings.

## Ask an agent to look at your sessions

An agent can tell you why a session cost so much and how to make it faster. It reads short reports from the `ccop` command. ccop adds nothing to `CLAUDE.md`, so your other sessions do not pay for it.

1. Right-click the menu bar item and choose **Install Command Line Tool…**. It links `ccop` into `~/.local/bin`.
2. Right-click a session in the list and choose **Copy for Agent**. It copies the instructions for agents and the session's id. **Help** in the same menu has a button that copies only the instructions, and `ccop guide` prints them.
3. Paste it into an agent and add your question. For example: "How can this session use fewer tokens?"

The reports the agent reads:

| Command | What it gives |
|---|---|
| `ccop brief <id>` | A short report on one session, about 2 KB |
| `ccop brief --since 7d` | The same for many sessions |
| `ccop top commands --since 7d` | A list of commands, causes, agents, sessions, turns, errors, projects or tips. `--by time` gives the slowest |
| `ccop cause <id> Bash` | The costliest calls of a tool or a program |
| `ccop time <id>` | Where the clock went: model, tools, subagents, waiting |
| `ccop call <id> <tool_use_id> --max-bytes 4000` | One tool call, cut at that size |

## Requirements

- macOS 14 or later
- Rust 1.97 (`rust-toolchain.toml` selects it if you use rustup)
- Swift 6 (Xcode 16 or the Command Line Tools)

## Install

Download `ccop-<version>.dmg` from [Releases](https://github.com/shchahrykovich/ccop/releases/latest), open it, and drag CCOP to Applications. The release is signed with a Developer ID and notarized by Apple.

Or build it from source and install it to `~/Applications`, then open it:

```
scripts/install.sh --user --launch
```

Without `--user` it installs to `/Applications`. A build from source is ad-hoc signed: it runs on your Mac, but it does not update itself.

The app has no Dock icon. Left-click the menu bar item to open the popover. Right-click it for the window, plan settings, Refresh, Help, the command line tool, updates and Quit.

## Updates

A release copy checks GitHub for a new version 30 seconds after it starts, then every 6 hours. When there is one, the popover shows "ccop X.Y.Z is available" with an Install button, and the right-click menu shows "Install ccop X.Y.Z…". Nothing is downloaded until you click Install.

What Install does:

1. Downloads the DMG from the GitHub release (https only, GitHub hosts only).
2. Checks the DMG with Gatekeeper: it must be signed with a Developer ID and notarized.
3. Quits ccop. A small script then checks that the new app has the same Team ID as the old one, replaces the app, and opens it. If a check fails, the old app stays and opens again.

The script writes a log to `~/Library/Logs/ccop/`. The app only replaces a copy in `/Applications` or `~/Applications`.

To turn off the automatic check, right-click the menu bar item and clear "Check for Updates Automatically". "Check for Updates…" checks at once.

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
scripts/build-app.sh            # builds "build/CCOP Dev.app" (a local build: own name and icon, no updates)
```

`CLAUDE.md` has more detail on the architecture and the transcript format.

## Releases

A release needs a "Developer ID Application" certificate in the keychain and notary credentials. Copy `scripts/notarize.env.example` to `.env.notarize` and fill it in. Git ignores that file.

```
scripts/build-app.sh --developer-id     # build/CCOP.app signed with Developer ID and the hardened runtime
scripts/release.sh --notarize           # bump the patch version, build, make dist/ccop-<version>.dmg, notarize
scripts/publish.sh                      # all of the above, then a GitHub release with the DMG
```

`publish.sh` takes `--patch` (the default), `--minor`, `--major`, `--set X.Y.Z` or `--no-bump`. Commit and push the new version in `Cargo.toml` after a release.

## License

MIT
