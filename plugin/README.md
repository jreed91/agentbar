# AgentBar for Claude Code

This Claude Code mod connects your sessions to [AgentBar](https://github.com/jreed91/agentbar),
a macOS menu bar app. When Claude asks a question, needs a permission, or goes idle, AgentBar
notifies you and brings the right terminal forward. A band above the prompt also lists your
*other* sessions that are waiting on you.

It needs **Claude Code 2.1.287 or newer** and the AgentBar app (`brew install --cask agentbar`
after `brew tap jreed91/agentbar https://github.com/jreed91/agentbar`). It loads on install and
has no settings of its own. The whole mod is one file, [`hooks/agentbar.tsx`](hooks/agentbar.tsx).

It only notifies: it never answers a prompt and never changes a decision. It also fails open.
If AgentBar is missing, not running, or returns an error, every event goes on unchanged, as
if the mod were not installed.

## What each hook decides or changes

| Hook | When it fires | What it does |
| --- | --- | --- |
| `classic.UserPromptSubmit`, `classic.PermissionDenied`, `classic.PostToolUse`, `classic.PostToolUseFailure`, `classic.Elicitation`, `classic.Notification`, `classic.Stop`, `classic.SubagentStop`, `classic.SessionEnd`, `classic.StopFailure` | On each of those Claude Code events | Sends the event to AgentBar in the background and returns `next(e)`. It decides nothing and changes nothing. |
| `classic.PermissionRequest` | When Claude Code shows a permission dialog | Sends the request to AgentBar in the background and returns `next(e)`. It never allows or denies anything: your own permission rules and your answer in the terminal decide. |
| `tool.call` for `AskUserQuestion` only | When Claude asks you a multiple-choice question | Sends the question to AgentBar, then returns what `next(e)` gives back, which is your answer in the terminal. Once the question is settled (answered, refused, dismissed or interrupted), it tells AgentBar to clear the row. It never answers the question or stands in for the tool, and no other tool is touched. |
| `turn.complete` | When a turn ends | If the main session's turn was interrupted (Esc), tells AgentBar to clear any prompt it still shows for this session. Returns `next(e)`. |
| `session.start` | When a session starts | In an interactive session, starts polling AgentBar every 2 seconds for other waiting sessions. Returns what `next(e)` gave back. |
| `ui.render` for `AbovePrompt` | When the area above the prompt is drawn | Draws a row for each other session waiting on you, with a **Jump** button. With nothing waiting, it returns `next(e)` and draws nothing. |

## What it sends, and where

Everything goes to the AgentBar app on the same Mac, at `http://127.0.0.1:<port>`. The port
and a per-launch bearer token are read from
`~/Library/Application Support/AgentBar/server.json`, which the app writes. **No other host
is contacted**, and nothing leaves your machine.

| Request | When | Body |
| --- | --- | --- |
| `GET /v1/health` | Before sending, to check the app is running | none |
| `POST /v1/<event>` | On each hook above | The event's hook input, the same JSON a classic command hook reads on stdin: session id, working directory, transcript path, and the event's fields (for example a permission request's tool name and input, or a question's text and options) |
| `GET /v1/attention` | Every 2 seconds in an interactive session | none |
| `POST /v1/focus` | When you press **Jump** | The session id to bring forward |

Each request also carries these headers: the bearer token, `X-AgentBar-Agent: claude`,
`X-AgentBar-Bridge: mod`, and, when known, the session's model, its context-window tokens
and size, and the `TERM_PROGRAM`, `TERMINAL_EMULATOR` and `__CFBundleIdentifier`
environment values. AgentBar uses the environment values to find the right terminal window
to focus.

## Programs it runs

The mod runs one fixed command, `open -g -b com.jreed91.AgentBar`, which is macOS's `open`
starting the AgentBar app in the background. It runs only when an event needs to be
delivered and AgentBar is not running, so a notification is not lost. The band's polls and
the clear requests never start it. The command works in the terminal only; in the desktop
Code tab it is refused and the event is dropped. The mod runs no shell and no other program.

## License

MIT, see [LICENSE](../LICENSE).
