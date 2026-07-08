# AgentBar — Implementation Plan

**AgentBar** is a native macOS menu bar app plus a zero-config Claude Code plugin. When a
Claude Code agent needs something from you — a multiple-choice question, a permission
prompt, or it's sitting idle waiting for input — AgentBar notifies you and (where the
hook system allows) lets you respond directly from the menu bar or the notification
banner, feeding your answer back into the running session.

This plan captures the decisions made during scoping and the full build-out.

---

## 1. Decisions (locked)

| Decision | Choice |
|---|---|
| App name | **AgentBar** (bundle ID `com.jreed91.AgentBar`, cask `agentbar`, plugin `agentbar`) |
| App stack | Native **Swift/SwiftUI** (`MenuBarExtra` + `UserNotifications`), no third-party dependencies |
| macOS floor | **macOS 14 Sonoma** |
| Events surfaced | Questions with options, permission requests, idle/waiting, task finished |
| Reply path | **Blocking hook + local server** — the hook POSTs to the app and blocks until the user answers |
| Permission UX | **Allow / Deny only** (deny carries an optional typed message); no "always allow" in v1 |
| Multi-session | **Queue grouped by session** — badge count on the icon, popover lists pending items per project |
| Notification UX | **Actionable banners + popover** — option buttons and text reply on the banner; full UI in the popover |
| Distribution | **Homebrew cask + plugin marketplace, everything in this repo**; release CI signs & notarizes with the owner's Apple Developer ID |

## 2. Hook mechanics (verified against Claude Code docs)

What the hook system can and cannot do shapes the whole design:

- **Hooks can block.** Command hooks have a configurable timeout (default 600s), so a
  hook may wait minutes for a human to answer in the menu bar.
- **`PreToolUse` on `AskUserQuestion`** receives the question(s) and options in
  `tool_input`. The hook cannot literally "answer" the tool, but it can return
  `permissionDecision: "deny"` with a `permissionDecisionReason` containing the user's
  answer. Claude receives that reason as feedback and continues with the answer instead
  of re-asking in the terminal. Returning nothing (exit 0, empty stdout) passes through
  to the normal terminal picker.
- **`PermissionRequest`** fires when a permission dialog would appear and can return
  `{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow" | "deny"}}}`
  (deny with a `message`). Empty output passes through to the terminal prompt.
- **`Notification`** fires when Claude is idle / waiting for input. It is
  informational — no hook output can respond to it.
- **`Stop`** fires when Claude finishes a turn — used for "task finished" banners.
- **No hook can inject a new user message** into an idle session. Therefore
  idle/waiting and task-finished are **notify-only**: the banner/popover focuses you
  back to the terminal rather than offering a reply box.
- **Plugins bundle hooks.** A plugin's `hooks/hooks.json` activates automatically on
  install — no `settings.json` editing. Hook commands reference bundled scripts via
  `${CLAUDE_PLUGIN_ROOT}`.

## 3. Architecture

```
┌────────────────────┐   stdin JSON    ┌──────────────────────┐
│ Claude Code session │ ──────────────▶│ plugin hook script    │
│  (any project/repo) │ ◀────────────── │  bin/agentbar-hook    │
└────────────────────┘  hook JSON out  └─────────┬────────────┘
                                                  │ HTTP POST /v1/<event>
                                                  │ (127.0.0.1, bearer token,
                                                  │  blocks until answered)
                                                  ▼
                                       ┌──────────────────────┐
                                       │  AgentBar.app         │
                                       │  • HookServer (NW)    │
                                       │  • QueueStore         │
                                       │  • MenuBarExtra UI    │
                                       │  • UNUserNotification │
                                       └──────────────────────┘
```

### Request flow (question example)

1. Claude calls `AskUserQuestion`; the plugin's `PreToolUse` hook fires.
2. `agentbar-hook ask` reads the payload from stdin, discovers the app's server via
   `~/Library/Application Support/AgentBar/server.json` (`{"port": N, "token": "hex"}`,
   mode 0600), launching the app with `open -g -b com.jreed91.AgentBar` if needed.
3. It POSTs the payload to `http://127.0.0.1:<port>/v1/ask` and blocks (curl
   `--max-time 590`, hook timeout 600).
4. AgentBar enqueues a `PendingItem`, updates the menu bar badge, and posts an
   actionable notification (option buttons + "type a reply" text action for
   single-question asks; multi-question asks open the popover).
5. The user answers from the banner or the popover. The server responds to the held
   HTTP request with the finished hook-output JSON.
6. The script prints that JSON to stdout; Claude Code consumes it and the agent
   continues with the user's answer.

**Fail-open contract:** if the app is missing, unreachable, errors, or the user doesn't
respond in time — the hook exits 0 with no output and the prompt appears in the
terminal as if AgentBar were never installed. The user can also explicitly click
"Answer in terminal" (passthrough) on any item.

### Local server protocol

| Route | Blocks? | Response body |
|---|---|---|
| `GET /v1/health` | no | `ok` |
| `POST /v1/ask` | yes | hook JSON (`PreToolUse` deny-with-answer) or empty = passthrough |
| `POST /v1/permission` | yes | hook JSON (`PermissionRequest` allow/deny) or empty = passthrough |
| `POST /v1/notify` | no | empty |
| `POST /v1/stop` | no | empty |

All routes require `Authorization: Bearer <token>`. The server binds 127.0.0.1 on an
ephemeral port; port + token are regenerated each app launch.

## 4. Repository layout

```
claude-notification/
├── .claude-plugin/marketplace.json    # marketplace at repo root → /plugin marketplace add jreed91/claude-notification
├── docs/
│   └── implementation-plan.md         # this document
├── plugin/                            # the Claude Code plugin ("agentbar")
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json               # PreToolUse(AskUserQuestion), PermissionRequest, Notification, Stop
│   └── bin/agentbar-hook              # dependency-free bash bridge (curl + sed only)
├── app/                               # Swift package for AgentBar.app
│   ├── Package.swift                  # swift-tools 5.9, platform .macOS(.v14), no deps
│   ├── Sources/AgentBar/
│   │   ├── AgentBarApp.swift          # @main, MenuBarExtra(.window), Settings scene, AppDelegate
│   │   ├── AppState.swift             # shared singleton wiring store + server + notifications
│   │   ├── Models.swift               # PendingItem, AskQuestion, HookEvent, payload parsing
│   │   ├── QueueStore.swift           # @MainActor ObservableObject; holds continuations for blocking items
│   │   ├── HookServer.swift           # NWListener HTTP server; writes server.json (0600)
│   │   ├── NotificationManager.swift  # UNUserNotificationCenter; per-item categories w/ actions + text input
│   │   ├── Views/
│   │   │   ├── QueueView.swift        # popover: pending items grouped by session/project
│   │   │   ├── QuestionItemView.swift # option buttons, multi-select, free-text "Other", submit, passthrough
│   │   │   ├── PermissionItemView.swift # tool + input detail, Allow / Deny(+message) / decide-in-terminal
│   │   │   └── SettingsView.swift     # per-event toggles, sounds, launch-at-login (SMAppService)
│   │   └── TerminalFocus.swift        # best-effort: activate the user's running terminal app
│   └── Support/Info.plist             # LSUIElement=true, bundle ID, min OS 14.0
├── Casks/agentbar.rb                  # Homebrew cask pointing at GitHub Releases
├── scripts/
│   ├── bundle.sh                      # assemble dist/AgentBar.app from the SPM binary
│   └── update-cask.sh                 # stamp version + sha256 into Casks/agentbar.rb
├── .github/workflows/
│   ├── ci.yml                         # build + shellcheck on PRs/main
│   └── release.yml                    # on tag v*: build, sign, notarize, release, update cask
├── Makefile                           # build / bundle / sign / notarize / zip / install
└── README.md
```

## 5. Component details

### 5.1 Plugin (`plugin/`)

- `hooks/hooks.json` registers four hooks, all pointing at
  `${CLAUDE_PLUGIN_ROOT}/bin/agentbar-hook <event>`:
  - `PreToolUse` matcher `AskUserQuestion`, timeout 600
  - `PermissionRequest` matcher `*`, timeout 600
  - `Notification` (no matcher), timeout 10
  - `Stop` (no matcher), timeout 10
- `bin/agentbar-hook` is plain bash using only `curl`, `sed`, and `open` (all present on
  stock macOS). No `jq`, no python. The app returns the *final* hook-output JSON, so the
  script never has to construct or transform JSON.

### 5.2 App (`app/`)

- **`HookServer`**: hand-rolled minimal HTTP/1.1 over `Network.framework`
  (`NWListener`). Parses request line, headers, `Content-Length` body; checks the
  bearer token; dispatches to `QueueStore` and holds the connection open until the item
  resolves. `Connection: close` semantics; 1 MiB body cap; 401 on bad token.
- **`QueueStore`** (`@MainActor`): the source of truth for the popover and badge.
  Blocking submissions (`ask`, `permission`) suspend on a `CheckedContinuation` stored
  on the `PendingItem`; resolving the item (from banner action, popover, timeout, or
  passthrough) resumes it with the hook JSON (or nil = passthrough/empty body).
  Informational items (`notify`, `stop`) render as dismissible rows and auto-expire.
- **Hook output construction** (in-app):
  - Question answered →
    `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "The user answered via the AgentBar menu bar app. <answers>. Use these answers and continue — do not re-ask."}}`
  - Permission allow/deny →
    `{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}` /
    `{"decision": {"behavior": "deny", "message": "<typed reason>"}}`
- **`NotificationManager`**: registers a unique `UNNotificationCategory` per pending
  item so banners can carry item-specific option buttons (up to 3 option actions + one
  `UNTextInputNotificationAction` for typed replies; permissions get Allow/Deny).
  Multi-question asks and overflow (>3 options) fall back to "open the popover".
  Default click activates the app; idle/stop banners invoke `TerminalFocus`.
- **UI**: `MenuBarExtra` in `.window` style. Icon shows a badge count of items awaiting
  response. Popover groups items by session (labelled with the project directory name,
  full `cwd` as subtitle), newest first; each item renders its interactive view inline.
- **Settings**: per-event enable toggles (questions / permissions / idle / task
  finished), banner sound on/off, launch-at-login via `SMAppService`.

### 5.3 Distribution

- **Cask** (`Casks/agentbar.rb`): installs `AgentBar.app` from GitHub Releases;
  `depends_on macos: ">= :sonoma"`. Users install with
  `brew tap jreed91/claude-notification https://github.com/jreed91/claude-notification && brew install --cask agentbar`
  (explicit-URL tap, since the repo isn't named `homebrew-*`).
- **Plugin**: `/plugin marketplace add jreed91/claude-notification` then
  `/plugin install agentbar@agentbar`.
- **Release CI** (`release.yml`, on tag `v*`): `swift build -c release` on a macOS
  runner → `scripts/bundle.sh` → `codesign --options runtime` with the imported
  Developer ID certificate → `xcrun notarytool submit --wait` + `stapler` → zip →
  GitHub Release → `scripts/update-cask.sh` commits the new version/sha256 to `main`.
  Required repo secrets: `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`,
  `MACOS_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.

## 6. Build phases

1. **Plugin scaffold** — marketplace.json, plugin.json, hooks.json, `agentbar-hook`
   script. *(done)*
2. **Plan docs** — this document. *(done)*
3. **App core** — Swift package; models + payload parsing; `QueueStore` with
   continuations; `HookServer` with health/ask/permission/notify/stop routes and
   server.json publication.
4. **App UI** — `MenuBarExtra` + badge, `QueueView` grouped by session,
   `QuestionItemView`, `PermissionItemView`, settings pane.
5. **Notifications** — actionable banners, per-item categories, text-input replies,
   delegate routing back into `QueueStore`, terminal focus for notify-only events.
6. **Packaging** — Info.plist, `bundle.sh`, Makefile (`build/bundle/sign/notarize/zip/install`).
7. **Distribution** — cask, `update-cask.sh`, `ci.yml`, `release.yml`, README with
   install + development instructions.
8. **Manual verification on a Mac** — build, install the plugin from the local
   marketplace, exercise all four event types, confirm fail-open behavior with the app
   quit. *(requires a macOS machine — the scaffold is authored in a Linux container)*

## 7. Known limitations & risks

- **Idle and task-finished are notify-only** — hooks cannot inject a message into an
  idle session, so "type back" only exists where a blocking hook is in flight
  (questions and permissions).
- **Question answers arrive as a deny-reason**, not as a first-class
  `AskUserQuestion` answer. The reason text explicitly instructs Claude to treat it as
  the user's answer and not re-ask; this works well in practice but is a prompt-level
  contract, not an API-level one. If Claude Code ever ships a first-class "respond via
  hook" mechanism, swap it in.
- **`Notification` vs `PermissionRequest` overlap** — an unanswered permission prompt
  may also fire a `Notification` idle event. The app dedupes by suppressing idle
  banners for sessions that already have a pending permission/question item.
- **Notification banner actions require the app to be signed and bundled** — actionable
  banners don't work for a bare SPM binary; always run via the bundled `.app`.
- **Hook timeout ceiling** — if the user doesn't respond within ~10 minutes the hook
  times out and the prompt falls back to the terminal (by design, fail-open).
- **One machine, local only** — v1 has no remote/mobile story; the server binds
  loopback with a per-launch bearer token.
