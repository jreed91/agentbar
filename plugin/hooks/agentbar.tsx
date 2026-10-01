// AgentBar's Claude Code bridge, as a Claude Code mod.
//
// Every hook here observes and forwards: it hands the event to AgentBar's local HTTP server
// and passes it on with `next(e)` unchanged. AgentBar is notify-only, so no hook ever
// answers, rewrites or waits on a prompt; you still answer in the terminal.
//
// Fail-open contract: if AgentBar is missing, unreachable or errors in any way, the event is
// dropped silently, exactly as if AgentBar were never installed.
//
// The server and its payloads are the ones the `agentbar-hook` bash bridge speaks (and still
// speaks for Copilot): POST /v1/<event> with the classic hook input as the JSON body. The mod
// adds a few headers the app reads when present: the bridge kind, the session's model, and
// its live context-window fill.
//
// The same module draws AgentBar inside the terminal: a one-line band above the prompt
// naming the *other* sessions waiting on you, so you need not glance at the menu bar. It
// polls `GET /v1/attention` while the session is interactive and draws nothing when no other
// session waits, AgentBar is not running, or a survey holds the band. It stays notify-only:
// "Jump" (or `j` with the band focused, ctrl+x tab) asks AgentBar to bring that session's
// terminal forward, and you answer there. A poll never launches AgentBar; only an event the
// bridge must deliver does.

import { atom, read, update } from 'claude-code'
import type { EngineInterface as $, Register } from 'claude-code'

import type { AgentBarWaiting } from '../types'

const BUNDLE_ID = 'com.jreed91.AgentBar'
const SERVER_FILE = 'Library/Application Support/AgentBar/server.json'

/** How often the band asks AgentBar who is waiting. */
const POLL_MS = 2000

/** Below this many columns the band drops the per-session list and keeps the count. */
const NARROW_COLUMNS = 72

const waiting = atom({ plugin: 'agentbar', key: 'waiting' } as const, [])
const jumpShortcut = atom({ plugin: 'agentbar', key: 'jumpShortcut' } as const, null)

// Classic (settings-hook) events → AgentBar endpoints. `classic.<Event>` hooks receive the
// same input the old command hooks read on stdin, so the bodies are byte-for-byte what the
// app already parses. Each `on` names its event literally, as the engine requires.
// AskUserQuestion rides `tool.call` instead (below).

type Server = { port: number; token: string }

// Cached across events; a reload starts it over, which only costs one re-read.
let server: Server | undefined

export const register: Register = on => {
  on('classic.UserPromptSubmit', ($, e, next) => (forward($, 'working', e), next(e)))
  on('classic.PermissionRequest', ($, e, next) => (forward($, 'permission', e), next(e)))
  on('classic.PermissionDenied', ($, e, next) => (forward($, 'denied', e), next(e)))
  on('classic.PostToolUse', ($, e, next) => (forward($, 'resolved', e), next(e)))
  on('classic.PostToolUseFailure', ($, e, next) => (forward($, 'resolved', e), next(e)))
  on('classic.Elicitation', ($, e, next) => (forward($, 'elicit', e), next(e)))
  on('classic.Notification', ($, e, next) => (forward($, 'notify', e), next(e)))
  on('classic.Stop', ($, e, next) => (forward($, 'stop', e), next(e)))
  on('classic.SubagentStop', ($, e, next) => (forward($, 'subagent', e), next(e)))
  on('classic.SessionEnd', ($, e, next) => (forward($, 'sessionend', e), next(e)))
  on('classic.StopFailure', ($, e, next) => (forward($, 'stopfailure', e), next(e)))

  // AskUserQuestion: forward before `next`, which resolves only once the question is
  // answered. The body mirrors the old PreToolUse hook input the app parses.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    // The envelope's reserved fields aside, `e` is the tool's input.
    const { tool, tool_use_id: _id, ...tool_input } = e
    forward($, 'ask', async () => ({
      hook_event_name: 'PreToolUse',
      session_id: await $.session.id(),
      cwd: await $.session.cwd(),
      tool_name: tool,
      tool_input,
    }))
    return next(e)
  })

  // The band.
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    // Only a person at a prompt sees the band; a `-p` run or the SDK draws nowhere.
    if (e.isInteractive) {
      void poll($)
      $.clock.every(POLL_MS, () => void poll($))
    }
    return started
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const others = await read($, waiting)
    if (e.props.hasSurvey || others.length === 0) return next(e)

    const shortcut = await read($, jumpShortcut)
    const { Box, Button, Text } = $.ui.resolve(e)
    const [first] = others
    const narrow = e.props.bodyColumns < NARROW_COLUMNS

    return (
      <Box flexDirection="row" gap={1}>
        <Text color="yellow">●</Text>
        <Text wrap="truncate-end">
          <Text bold>{headline(others.length)}</Text>
          {narrow ? '' : `: ${others.map(label).join(', ')}`}
        </Text>
        <Button
          key="jump"
          hotkey="j"
          plain
          label={narrow ? 'Jump' : `Jump to ${project(first!.cwd)}`}
          onPress={() => void jump($, first!.session_id)}
        />
        {shortcut && !narrow ? <Text dimColor>{`· ${shortcut} from anywhere`}</Text> : null}
      </Box>
    )
  })
}

type Attention = { sessions?: AgentBarWaiting[]; jump_shortcut?: string | null }

function headline(count: number): string {
  return count === 1 ? '1 other session needs you' : `${count} other sessions need you`
}

/** `api (permission)`: the project, and what it waits on. */
function label(entry: AgentBarWaiting): string {
  return `${project(entry.cwd)} (${entry.status})`
}

function project(cwd: string): string {
  return cwd.split('/').filter(Boolean).pop() ?? 'session'
}

/**
 * Asks AgentBar who is waiting and keeps everyone but this session. Fail-open: when the app
 * is down or answers oddly, the band empties rather than showing stale sessions.
 */
async function poll($: $): Promise<void> {
  const attention = await safe(() => fetchAttention($))
  const self = await safe(() => $.session.id())
  const others = (attention?.sessions ?? []).filter(entry => entry.session_id !== self)
  const shortcut = attention?.jump_shortcut ?? null

  // Write only on change, so an unchanged poll redraws nothing.
  if (JSON.stringify(others) !== JSON.stringify(await read($, waiting))) {
    await update($, waiting, () => others)
  }
  if (shortcut !== (await read($, jumpShortcut))) {
    await update($, jumpShortcut, () => shortcut)
  }
}

async function fetchAttention($: $): Promise<Attention | undefined> {
  const target = await connect($, { launch: false })
  if (!target) return undefined
  const response = await $.http.fetch(`http://127.0.0.1:${target.port}/v1/attention`, {
    headers: { ...(await headers($)), Authorization: `Bearer ${target.token}` },
  })
  if (!response.ok) return undefined
  const parsed = JSON.parse(response.text) as Attention
  return Array.isArray(parsed.sessions) ? parsed : undefined
}

/** Asks AgentBar to bring that session's terminal forward. Fail-open. */
async function jump($: $, sessionID: string): Promise<void> {
  try {
    const target = await connect($, { launch: false })
    if (!target) return
    await $.http.fetch(`http://127.0.0.1:${target.port}/v1/focus`, {
      method: 'POST',
      headers: { ...(await headers($)), Authorization: `Bearer ${target.token}` },
      body: JSON.stringify({ session_id: sessionID }),
    })
  } catch {
    // Fail open.
  }
}

/**
 * Posts one event to AgentBar without holding up the session. Never throws and never
 * rejects: every failure is swallowed (fail-open).
 */
function forward($: $, endpoint: string, body: object | (() => Promise<object>)): void {
  void (async () => {
    try {
      const target = await connect($, { launch: true })
      if (!target) return
      const payload = typeof body === 'function' ? await body() : body
      await $.http.fetch(`http://127.0.0.1:${target.port}/v1/${endpoint}`, {
        method: 'POST',
        headers: { ...(await headers($)), Authorization: `Bearer ${target.token}` },
        body: JSON.stringify(payload),
      })
    } catch {
      // Fail open.
    }
  })()
}

/**
 * The live server. With `launch`, AgentBar is opened first when it is not answering (the
 * bridge's events); without it, a missing app is just undefined (the band's polls, which
 * must never start the app on their own).
 */
async function connect($: $, { launch }: { launch: boolean }): Promise<Server | undefined> {
  if (server && (await alive($, server))) return server
  server = await readServerFile($)
  if (server && (await alive($, server))) return server
  if (!launch) return (server = undefined)

  // Not answering: launch the app and wait for it to publish a fresh server.json. Never
  // delete the file here (see the bash bridge for why). Starting programs works in the
  // terminal only; elsewhere `$.process.run` rejects and the event is dropped.
  server = undefined
  try {
    const opened = await $.process.run(['open', '-g', '-b', BUNDLE_ID], { timeoutMs: 5000 })
    if (opened.exitCode !== 0) return undefined
  } catch {
    return undefined
  }
  for (let attempt = 0; attempt < 25; attempt++) {
    await $.clock.sleep(200)
    const candidate = await readServerFile($)
    if (candidate && (await alive($, candidate))) return (server = candidate)
  }
  return undefined
}

async function readServerFile($: $): Promise<Server | undefined> {
  try {
    const home = await $.env.get('HOME')
    if (!home) return undefined
    const parsed = JSON.parse(await $.fs.read(`${home}/${SERVER_FILE}`)) as Partial<Server>
    return typeof parsed.port === 'number' && typeof parsed.token === 'string' && parsed.token
      ? { port: parsed.port, token: parsed.token }
      : undefined
  } catch {
    return undefined
  }
}

async function alive($: $, target: Server): Promise<boolean> {
  try {
    const health = await $.http.fetch(`http://127.0.0.1:${target.port}/v1/health`, {
      headers: { Authorization: `Bearer ${target.token}` },
    })
    return health.ok
  } catch {
    return false
  }
}

/**
 * The extra headers: terminal clues for "Focus" (as the bash bridge sends them), the bridge
 * kind for the Setup panel, and the session's model and context fill for the row's meta
 * line. Each is best-effort and left out when unknown.
 */
async function headers($: $): Promise<Record<string, string>> {
  const out: Record<string, string> = {
    'Content-Type': 'application/json',
    'X-AgentBar-Agent': 'claude',
    'X-AgentBar-Bridge': 'mod',
  }
  // CR/LF stripped so an environment value can never smuggle in another header.
  const set = (name: string, value: string | number | undefined) => {
    const text = value === undefined ? '' : String(value).replace(/[\r\n]/g, '')
    if (text) out[name] = text
  }
  set('X-AgentBar-Term', await safe(() => $.env.get('TERM_PROGRAM')))
  set('X-AgentBar-TermEmu', await safe(() => $.env.get('TERMINAL_EMULATOR')))
  set('X-AgentBar-Host', await safe(() => $.env.get('__CFBundleIdentifier')))
  set('X-AgentBar-Model', await safe(() => $.session.model()))
  const usage = await safe(() => $.session.usage())
  set('X-AgentBar-Context-Tokens', usage?.context.tokens)
  set('X-AgentBar-Context-Window', usage?.context.window)
  return out
}

async function safe<T>(read: () => Promise<T>): Promise<T | undefined> {
  try {
    return await read()
  } catch {
    return undefined
  }
}
