# Paseo feature analysis → AgentBar dashboard

A comparison of [getpaseo/paseo](https://github.com/getpaseo/paseo) against AgentBar, and the
decision on which of Paseo's ideas to bring into AgentBar — plus the roadmap we're building
against.

## What Paseo is

Paseo is a **multi-agent coding orchestration platform**: a local daemon that runs and
coordinates many AI coding agents in parallel, exposed over a WebSocket API to Electron
desktop, Expo mobile, web, and CLI clients. It is a two-way control surface — you drive
agents from it.

Headline features:

- **Self-hosted daemon** running agents in parallel on your own machines
- **Multi-provider** — Claude Code, Codex, Copilot, OpenCode, Pi behind one interface
- **Cross-platform clients** — iOS, Android, desktop, web, CLI; "ship from your phone or your desk"
- **Remote connectivity** with QR-code pairing to a remote daemon
- **Live streaming** — attach to a running agent and watch its output in real time
- **Follow-up tasks** — send new instructions to an agent mid-run
- **Skills system** — orchestration primitives (handoffs, Ralph loops, advisor/committee)
- **Voice control** — dictation + problem-discussion mode
- **Privacy-focused** — no telemetry, no mandatory auth

## What AgentBar is

AgentBar is a deliberately narrow, **macOS-native, notify-only** menu bar app for Claude
Code. Its defining contract is the opposite of Paseo's control surface:

- Never blocks a session (hooks are fire-and-forget; the server acks immediately)
- Never answers a prompt for you — every prompt is answered in the terminal
- Fail-open — if the app is missing or errors, the hook exits cleanly as if it weren't there
- No reply channel back into a session

So most of Paseo's value lives in exactly the area AgentBar intentionally avoids (two-way
control, orchestration, multi-provider). That is a feature of AgentBar, not a gap to close.

## Decision

We keep the notify-only contract intact and pull in **only the read-only, "awareness"
slice** of Paseo — the part that makes many parallel Claude sessions legible at a glance.
Concretely:

| Paseo feature | Verdict | Why |
|---|---|---|
| Multi-agent parallel view | **Adopt (read-only)** | Fits AgentBar's monitoring identity; builds on the existing session roster |
| Live streaming / "attach" | **Adopt (read-only, from disk)** | Show what each agent is doing, parsed from the transcript AgentBar already reads — no new IPC, no control |
| Reply / follow-up channel | **Rejected** | Breaks the never-block, fail-open, answer-in-terminal contract |
| Multi-provider (Codex/Copilot/…) | **Out of scope** | AgentBar keys entirely off Claude Code hooks + transcripts |
| Remote daemon / QR pairing | **Out of scope (for now)** | Stay macOS-native, localhost-only |
| Mobile / web / CLI clients | **Out of scope (for now)** | Single Swift menu bar app |
| Voice control | **Out of scope** | Not aligned with a passive menu bar notifier |

Platform stays macOS-native. No reply channel. No orchestration.

## Roadmap — the read-only dashboard

AgentBar already merges an on-disk transcript scan (`SessionScanner` → `ClaudeSession`)
with live hook events into `QueueStore.sessionRows`, one row per project location with a
status. The dashboard is an **evolution of that feed**, not a new subsystem.

### Slice 1 — current activity + summary (this change)

- **Current-activity extraction.** The scanner reads each session's `.jsonl`; extract the
  most recent action — the last `tool_use` block, rendered compactly ("Editing
  QueueStore.swift", "Running: swift build", "Searching …"), or a text snippet when the
  last message is prose. Added to `ClaudeSession.activity` and carried onto `SessionRow`.
  This is Paseo's "attach and watch," done read-only from disk with zero new plumbing.
- **Dashboard summary strip.** A compact `● N need you · ⚙ N working · ○ N idle` header
  above the feed (`QueueStore.dashboardSummary`), for the parallel overview Paseo leads
  with.
- **Per-session activity line.** For sessions not currently waiting on you, show
  `⋯ <what it's doing>` under the title, so the feed reads like a live agent dashboard
  rather than only an attention queue.

### Slice 2 — live working timers

- Show turn-elapsed on actively-working sessions (mirror the existing `WaitingLabel`
  pattern, keyed off the `working` hook's start time already tracked in `turnStart`).

### Slice 3 — per-session drill-in

- Click a session to expand a read-only recent-activity trail (the last N tool calls from
  the transcript) — the closest read-only analog to Paseo's live stream, without attaching
  to the process.

### Slice 4 — grouping / filtering

- Optional grouping of the roster by state (Needs you / Working / Idle) and a filter to
  hide quiet historical sessions, for machines running many agents at once.

## Non-goals (explicit)

To keep the contract legible, these stay off the table unless the decision above is
revisited: any reply/follow-up channel, blocking hooks, agent control, multi-provider
support, remote/mobile clients, and voice.
