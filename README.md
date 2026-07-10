# AgentBar

A native macOS menu bar app plus a zero-config Claude Code plugin. When a Claude Code
agent needs something from you — a multiple-choice question, a permission prompt, or it
has gone idle waiting for input — AgentBar notifies you and brings your terminal back to
the front so you can answer there. It is a **notification tool, not an input tool**: it
never blocks your session and never sits between you and Claude.

## How it works

```
Claude Code session → plugin hook → AgentBar local server → menu bar / banner
        │                              (returns immediately)
        └── session continues; you answer the prompt in your terminal
```

1. The plugin registers hooks across Claude Code's interaction points: turn starts
   (`UserPromptSubmit`, surfaced as a live "thinking" status), questions
   (`AskUserQuestion`), permission requests, MCP input requests (`Elicitation`), tool
   completions (`PostToolUse`, used to auto-clear a prompt once you answer it in the
   terminal), idle notifications, and the task-finished / subagent-finished / session-ended
   / run-interrupted (`Stop`, `SubagentStop`, `SessionEnd`, `StopFailure`) events.
2. When one fires, the bundled `bin/agentbar-hook` script reads the payload and POSTs it
   to AgentBar's local HTTP server (`127.0.0.1`, ephemeral port, per-launch bearer token
   published to `~/Library/Application Support/AgentBar/server.json`). It launches the
   app first if it is not already running.
3. The server acknowledges immediately (fire-and-forget), so the hook returns at once and
   your session is never blocked. AgentBar queues the item, badges the menu bar icon, and
   posts a notification showing what Claude is asking.
4. You answer the prompt in your terminal as usual. Clicking the banner (or the "Focus"
   button in the popover) brings the session's own terminal/IDE window back to the front.
   Once you answer, AgentBar notices the session make progress (`PostToolUse` / `Stop`) and
   clears the item automatically.

**Fail-open contract:** the CLI always returns immediately. If the app is missing,
unreachable, or errors in any way, the hook exits cleanly with no output — exactly as if
AgentBar were never installed. Because AgentBar never returns a decision to Claude Code,
every prompt is always answered in the terminal.

## Install

AgentBar has two halves — the **app** (menu bar UI) and the **plugin** (the hooks that
feed it). Install both.

### 1. App (Homebrew cask)

```sh
brew tap jreed91/claude-notification https://github.com/jreed91/claude-notification
brew install --cask agentbar
```

Then launch AgentBar once so macOS can grant it notification permission. The explicit tap
URL is required because the repository is not named `homebrew-*`.

### 2. Plugin (Claude Code marketplace)

In Claude Code:

```
/plugin marketplace add jreed91/claude-notification
/plugin install agentbar@agentbar
```

The plugin's hooks activate automatically on install — no `settings.json` editing needed.

## What AgentBar shows you

Every event is a notification — AgentBar never intercepts or answers a prompt for you.

| Event | What you see | What you do |
|---|---|---|
| **Thinking** (`UserPromptSubmit`) | A live "working" status while Claude is on a turn (no banner) | Nothing — it clears itself when the turn ends |
| **Question** (`AskUserQuestion`) | The question and its options, for context | Answer in the terminal; click to focus it |
| **Permission request** | The tool and its input, so you know what Claude wants | Allow/deny in the terminal; click to focus it |
| **MCP input request** (`Elicitation`) | The server's message and the fields it wants | Fill it in the terminal; click to focus it |
| **Idle / waiting** | Claude is waiting for input | Click to focus the terminal |
| **Task finished** (`Stop`) | The turn completed | Click to focus the terminal |
| **Subagent finished** (`SubagentStop`) | A spawned subagent completed | — |
| **Session ended** (`SessionEnd`) | The session closed | — |
| **Run interrupted** (`StopFailure`) | Surfaces API errors such as rate limits, overload, or billing problems | — |

Questions, permissions, and MCP input requests badge the icon and stay in the popover
until they're resolved. There is no reply channel back into the session, so AgentBar can't
clear them the instant you answer — instead it watches for the session to make progress
(the next tool run, or the turn finishing) and clears them then, which in practice is a
beat after you respond in the terminal. You can also dismiss any item by hand. Informational
rows auto-expire. Every event has a toggle in Settings, so chatty ones (subagent and
session-end in particular) can be muted individually.

## The session list

The popover lists every Claude Code session on your machine, newest first. The roster is
read straight from Claude Code's on-disk transcripts (`~/.claude/projects/**/*.jsonl`, or
under `$CLAUDE_CONFIG_DIR`), so sessions show up even if they started before AgentBar was
running or live in a terminal that never sent a hook. Each row shows the session's project,
its first prompt as a title, a message count, and when it was last active; quiet sessions
are tagged `IDLE`.

Live hook events fold into the matching row by session id: a session waiting on a question
or permission rises to the top, tags itself `QUESTION` / `PERMISSION`, and shows the prompt
(and any command) inline with the same focus/dismiss keycaps. When you answer in the
terminal, the row settles back to its resting state. The scan runs only while the popover is
open — on open and on a light interval — and parses just the most recent sessions, caching
by file modification date so repeat scans are nearly free.

The popover is taller-adjustable — drag the handle on its bottom edge to grow it downward —
and the height is remembered across launches.

## Development

Building requires **macOS 14+ with the Xcode command line tools** (`xcode-select
--install`).

A local ad-hoc (unsigned) build installed to `/Applications`:

```sh
make bundle install
```

Other useful targets: `make build`, `make bundle`, `make adhoc`, `make clean`. See the
`Makefile` for signing, zipping, and notarizing targets.

Repository layout:

```
claude-notification/
├── .claude-plugin/marketplace.json    # plugin marketplace (repo root)
├── docs/implementation-plan.md        # full design & decisions
├── plugin/                            # the Claude Code plugin ("agentbar")
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json               # PreToolUse / PermissionRequest / Elicitation / Notification / Stop / SubagentStop / SessionEnd / StopFailure
│   └── bin/agentbar-hook              # dependency-free bash bridge (curl + sed)
├── app/                               # Swift package for AgentBar.app
│   ├── Package.swift
│   ├── Sources/AgentBar/
│   └── Support/Info.plist
├── Casks/agentbar.rb                  # Homebrew cask → GitHub Releases
├── scripts/
│   ├── bundle.sh                      # assemble dist/AgentBar.app
│   └── update-cask.sh                 # stamp version + sha256 into the cask
├── .github/workflows/                 # ci.yml, release.yml
├── Makefile
└── README.md
```

## Commits & releasing

Releases are **fully automated** from the commit history — there is no manual tag step.

### Conventional Commits

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).
The type prefix drives the next version and the generated release notes:

| Prefix | Example | Release effect |
|---|---|---|
| `fix:` | `fix: stop popover header from clipping` | patch (`0.3.0` → `0.3.1`) |
| `feat:` | `feat: add per-session mute toggle` | minor (`0.3.0` → `0.4.0`) |
| `feat!:` / `BREAKING CHANGE:` footer | `feat!: drop macOS 13 support` | major (`0.3.0` → `1.0.0`) |
| `docs:`, `chore:`, `refactor:`, `test:`, `ci:`, `style:`, `perf:` | `chore: bump deps` | no release |

The **Lint commit messages** CI job (commitlint) enforces this on every pull request, so
non-conforming commits are caught before they reach `main`. Config lives in
`commitlint.config.js`.

### Automated releases

On every push to `main`, `release.yml` runs [semantic-release](https://semantic-release.gitbook.io/):

1. It analyzes the commits since the last `v*` tag and decides the next version (or exits
   if nothing warrants a release).
2. `scripts/release-build.sh` builds, signs, notarizes, and zips `AgentBar.app` for that
   version and stamps `Casks/agentbar.rb`.
3. semantic-release tags `vX.Y.Z`, publishes a GitHub Release with generated notes and the
   zip asset, and commits the updated cask back to `main` (`chore(release): … [skip ci]`).

No `settings.json` or tag pushing needed — merge a `fix:`/`feat:` PR and the release ships
itself.

Required repository secrets:

| Secret | Purpose |
|---|---|
| `MACOS_CERT_P12` | Base64-encoded Developer ID Application certificate (`.p12`) |
| `MACOS_CERT_PASSWORD` | Password for the `.p12` |
| `MACOS_SIGNING_IDENTITY` | Codesign identity, e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_APP_PASSWORD` | App-specific password for notarization |

## Design

See [docs/implementation-plan.md](docs/implementation-plan.md) for the full design,
hook mechanics, server protocol, and known limitations.