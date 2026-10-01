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

import type { EngineInterface as $, Register } from 'claude-code'

const BUNDLE_ID = 'com.jreed91.AgentBar'
const SERVER_FILE = 'Library/Application Support/AgentBar/server.json'

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
}

/**
 * Posts one event to AgentBar without holding up the session. Never throws and never
 * rejects: every failure is swallowed (fail-open).
 */
function forward($: $, endpoint: string, body: object | (() => Promise<object>)): void {
  void (async () => {
    try {
      const target = await connect($)
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

/** The live server, launching AgentBar first when it is not answering. */
async function connect($: $): Promise<Server | undefined> {
  if (server && (await alive($, server))) return server
  server = await readServerFile($)
  if (server && (await alive($, server))) return server

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
