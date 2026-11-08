# ccop help

ccop shows all Claude Code sessions on this Mac and where their tokens go. It reads the transcripts that Claude Code writes to `~/.claude/projects`. Your sessions never leave your Mac.

This page is for version {{VERSION}}. Source code and issues: <https://github.com/shchahrykovich/ccop>.

## Ask an agent to look at your sessions

An agent can tell you why a session cost so much and how to make it faster. It reads short reports from the `ccop` command.

ccop adds nothing to `CLAUDE.md`, so your other sessions do not pay for it. You give the instructions to one agent, when you need them:

1. In the menu of the menu bar icon (right click), choose **Install Command Line Tool…**. It links `ccop` into `~/.local/bin`.
2. Give an agent the instructions in one of these ways:
   - Right-click a session in the list and choose **Copy for Agent**. It copies the instructions and that session's id.
   - On this page, click **Copy for Agent** at the top. It copies the instructions.
   - Tell the agent: "Run `ccop guide` and follow it".
3. Paste, and add your question. For example: "How can this session use fewer tokens?"

## Flag a session

To keep a session easy to find, right-click it in the list and choose **Flag**. The flag button beside the session's title does the same. To see all flagged sessions, of any age, choose **Flagged** beside Today, 7 days, 30 days and All. Search and the folder filter also apply to this list.

Flags stay on this Mac, in the settings of the app. The `ccop` command does not know about them.

## Tools and MCP servers

In the window, choose **Tools** at the top of the list. The list then shows the MCP servers and Claude Code's own tools of the sessions that the period, the search and the folder filter keep, with their cost and the number of sessions that called them.

- **All tools** shows a table: which project uses which tool or server, with the cost and the number of sessions in each cell.
- A server or a tool shows its tools, its cost by project, and each session that called it. Click a session to open it at its Cause tab.

The cost of a tool is the cost of the model calls that read its results, not the price of running it.

## Commands

All commands take `--json`. `ID` is the start of a session id.

| Command | What it gives |
|---|---|
| `ccop sessions --since 7d` | Sessions, the newest first |
| `ccop show ID` | One session: tokens, models, resume command |
| `ccop projects` | Sessions and tokens by project folder |
| `ccop usage --days 7` | Tokens and API-equivalent cost by day |
| `ccop brief ID` | A short report on one session |
| `ccop brief --since 7d` | A short report on many sessions |
| `ccop top commands --since 7d` | A list of commands, causes, agents, sessions, turns, errors, projects or tips |
| `ccop tools --since 7d` | MCP servers and tools: cost, calls, sessions, projects |
| `ccop cause ID Bash` | The costliest calls of a tool or a program |
| `ccop time ID` | Where the clock went: model, tools, subagents, waiting |
| `ccop anatomy ID` | Everything about one session: turns, lanes, tools, tips |
| `ccop context ID --call N` | What fills the context of one model call: files, commands, answers |
| `ccop chat ID` | The texts of one lane |
| `ccop call ID TOOL_USE_ID` | One tool call in full |
| `ccop guide` | The instructions for agents |

## Instructions for agents

{{GUIDE}}
