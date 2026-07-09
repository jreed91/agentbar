# AgentBar

A native macOS menu bar app plus a zero-config Claude Code plugin. When a Claude Code
agent needs something from you — a multiple-choice question, a permission prompt, or it
has gone idle waiting for input — AgentBar notifies you and, where the hook system
allows, lets you answer directly from the menu bar or the notification banner, feeding
your response back into the running session.

## How it works

```
Claude Code session → plugin hook → AgentBar local server → menu bar / banner
                                                                     │
        session continues with your answer ◀── answer fed back ──────┘
```

1. The plugin registers hooks for `AskUserQuestion`, permission requests, idle
   notifications, and task-finished (`Stop`) events.
2. When one fires, the bundled `bin/agentbar-hook` script reads the payload and POSTs it
   to AgentBar's local HTTP server (`127.0.0.1`, ephemeral port, per-launch bearer token
   published to `~/Library/Application Support/AgentBar/server.json`). It launches the
   app first if it is not already running.
3. AgentBar queues the item, badges the menu bar icon, and posts an actionable
   notification. You answer from the banner or the popover.
4. For blocking events (questions, permissions), the server holds the HTTP request open
   until you respond, then returns the hook-output JSON. The script prints it to stdout
   and the agent continues with your answer.

**Fail-open contract:** if the app is missing, unreachable, errors, or you do not respond
within the hook timeout (~10 minutes), the hook exits cleanly with no output and the
prompt falls back to the normal terminal experience — exactly as if AgentBar were never
installed. Every item also has an explicit "Answer in terminal" passthrough.

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

## What you can answer from the menu bar

| Event | What you can do | Why |
|---|---|---|
| **Question** (`AskUserQuestion`) | Pick an option or type a free-text reply | A blocking hook is in flight, so your answer can be fed back as the agent's answer. |
| **Permission request** | Allow, or Deny with an optional message | A blocking hook can return an allow/deny decision to Claude Code. |
| **Idle / waiting** | Notify only — focuses your terminal | No hook can inject a new message into an idle session, so there is nothing to reply to. |
| **Task finished** (`Stop`) | Notify only — focuses your terminal | Informational; the turn is already complete. |

Questions and permissions are interactive because a hook is blocking and can carry a
response back. Idle and task-finished are notify-only: the banner just brings your
terminal back to the front.

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
│   ├── hooks/hooks.json               # PreToolUse / PermissionRequest / Notification / Stop
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