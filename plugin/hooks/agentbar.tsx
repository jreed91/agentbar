// AgentBar's Claude Code bridge, as a Claude Code mod.
//
// Most hooks here observe and forward: they hand the event to AgentBar's local HTTP server
// and pass it on with `next(e)` unchanged.
//
// Two hooks can also take an answer from the menu bar, when "Answer prompts from the menu
// bar" is turned on in AgentBar's Settings (it is off by default): a permission request
// (allow or deny) and an AskUserQuestion (pick the options). The prompt still opens in the
// terminal at the same time; whichever you answer first wins and the other one closes.
// With the setting off, AgentBar replies that it won't answer and the hook steps aside at
// once, so the session behaves exactly as a notify-only bridge would.
//
// Fail-open contract: if AgentBar is missing, unreachable or errors in any way, the event is
// dropped silently and the prompt is answered in the terminal, exactly as if AgentBar were
// never installed.
//
// The server and its payloads are the ones the `agentbar-hook` bash bridge speaks (and still
// speaks for Copilot): POST /v1/<event> with the classic hook input as the JSON body. The mod
// adds a few headers the app reads when present: the bridge kind, the session's model, and
// its live context-window fill.
//
// The same module draws AgentBar inside the terminal: a band above the prompt with a row for
// each *other* session waiting on you (project, what it asks, how long it has waited), so
// you need not glance at the menu bar. It polls `GET /v1/attention` while the session is
// interactive and draws nothing when no other session waits, AgentBar is not running, or a
// survey holds the band. The band only notifies: a row's "Jump" (or `j` for the first, with
// the band focused: ctrl+x tab) asks AgentBar to bring that session's terminal forward, and
// you answer there. A poll never launches AgentBar; only an event the bridge must deliver
// does.

import { atom, read, update } from 'claude-code'
import type { EngineInterface as $, Register } from 'claude-code'

import type { AgentBarWaiting } from '../types'

const BUNDLE_ID = 'com.jreed91.AgentBar'
const SERVER_FILE = 'Library/Application Support/AgentBar/server.json'

/** How often the band asks AgentBar who is waiting. */
const POLL_MS = 2000

/** Below this many columns a row drops the prompt's summary. */
const NARROW_COLUMNS = 72
/** From this many columns the first row also names AgentBar's global hotkey. */
const WIDE_COLUMNS = 100
/** Rows the band shows before folding the rest into "+N more". */
const MAX_ROWS = 3
/** The widest a project name gets before it is cut. */
const MAX_NAME = 20

const waiting = atom({ plugin: 'agentbar', key: 'waiting' } as const, [])
const jumpShortcut = atom({ plugin: 'agentbar', key: 'jumpShortcut' } as const, null)
const clockSeconds = atom({ plugin: 'agentbar', key: 'now' } as const, 0)

// Classic (settings-hook) events → AgentBar endpoints. `classic.<Event>` hooks receive the
// same input the old command hooks read on stdin, so the bodies are byte-for-byte what the
// app already parses. Each `on` names its event literally, as the engine requires.
// AskUserQuestion rides `tool.call` instead (below).

type Server = { port: number; token: string }

/** What AgentBar answered from the menu bar. */
type Answer =
  | { behavior: 'allow' }
  | { behavior: 'deny'; message?: string }
  | { answers: Record<string, string> }

/** How long one answer poll may be held open by the app before it replies "nothing yet". */
const ANSWER_POLL_MS = 3000
/** Upper bound on waiting for a menu-bar answer; the terminal prompt is open throughout. */
const MAX_WAIT_MS = 30 * 60 * 1000
const DENIED = 'Denied from the AgentBar menu bar.'

// Cached across events; a reload starts it over, which only costs one re-read.
let server: Server | undefined

export const register: Register = on => {
  on('classic.UserPromptSubmit', ($, e, next) => (forward($, 'working', e), next(e)))
  // Claude Code runs this hook while the permission dialog is already on screen and takes
  // whichever answers first, so waiting here never holds up the terminal prompt.
  on('classic.PermissionRequest', async ($, e, next) => {
    const beneath = await next(e)
    // A settings hook already decided, so no dialog opens and there is nothing to answer.
    if (beneath.decision) return (forward($, 'permission', e), beneath)
    const answer = await offer($, 'permission', e, next.signal)
    if (answer && 'behavior' in answer) {
      const decision =
        answer.behavior === 'allow'
          ? ({ behavior: 'allow' } as const)
          : ({ behavior: 'deny', message: answer.message || DENIED } as const)
      return { ...beneath, decision }
    }
    return beneath
  })
  on('classic.PermissionDenied', ($, e, next) => (forward($, 'denied', e), next(e)))
  on('classic.PostToolUse', ($, e, next) => (forward($, 'resolved', e), next(e)))
  on('classic.PostToolUseFailure', ($, e, next) => (forward($, 'resolved', e), next(e)))
  on('classic.Elicitation', ($, e, next) => (forward($, 'elicit', e), next(e)))
  on('classic.Notification', ($, e, next) => (forward($, 'notify', e), next(e)))
  on('classic.Stop', ($, e, next) => (forward($, 'stop', e), next(e)))
  on('classic.SubagentStop', ($, e, next) => (forward($, 'subagent', e), next(e)))
  on('classic.SessionEnd', ($, e, next) => (forward($, 'sessionend', e), next(e)))
  on('classic.StopFailure', ($, e, next) => (forward($, 'stopfailure', e), next(e)))

  // AskUserQuestion: offer it to AgentBar while `next` shows it in the terminal (`next`
  // resolves only once it is answered there). An answer from the menu bar returns first,
  // which closes the terminal dialog. The body mirrors the old PreToolUse hook input.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    // The envelope's reserved fields aside, `e` is the tool's input.
    const { tool, tool_use_id: _id, ...tool_input } = e
    let settled = false
    const terminal = next(e)
    terminal.then(
      () => (settled = true),
      () => (settled = true),
    )
    const menuBar = offer(
      $,
      'ask',
      async () => ({
        hook_event_name: 'PreToolUse',
        session_id: await $.session.id(),
        cwd: await $.session.cwd(),
        tool_name: tool,
        tool_input,
      }),
      next.signal,
      () => settled,
    )
    const first = await Promise.race([
      terminal.then(
        () => undefined,
        () => undefined,
      ),
      menuBar.then(answer => (answer && 'answers' in answer ? answer : undefined)),
    ])
    if (!first || settled) return terminal
    return { result: { questions: tool_input.questions, answers: first.answers } } as never
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
    const now = await read($, clockSeconds)
    const { Box, Button, Text } = $.ui.resolve(e)
    const columns = e.props.bodyColumns
    const rows = others.slice(0, MAX_ROWS)
    const hidden = others.length - rows.length
    // One column for the project names, so the asks line up under each other.
    const nameWidth = Math.min(MAX_NAME, Math.max(...rows.map(entry => project(entry.cwd).length)))

    return (
      <Box flexDirection="column">
        {rows.map((entry, index) => {
          const waited = now ? ago(now - entry.waiting_since) : ''
          return (
            <Box key={entry.session_id} flexDirection="row" gap={1}>
              <Text color={tone(entry.status)}>●</Text>
              <Box width={nameWidth} flexShrink={0}>
                <Text bold wrap="truncate-end">
                  {project(entry.cwd)}
                </Text>
              </Box>
              <Box flexGrow={1} flexShrink={1}>
                <Text wrap="truncate-end">
                  {ask(entry.status)}
                  {columns >= NARROW_COLUMNS && entry.summary ? (
                    <Text dimColor>{` · ${entry.summary}`}</Text>
                  ) : null}
                </Text>
              </Box>
              {waited ? <Text dimColor>{waited}</Text> : null}
              <Button
                key={`jump-${entry.session_id}`}
                {...(index === 0 ? { hotkey: 'j' } : {})}
                plain
                label="Jump"
                onPress={() => void jump($, entry.session_id)}
              />
              {index === 0 && shortcut && columns >= WIDE_COLUMNS ? (
                <Text dimColor>{`or ${shortcut}`}</Text>
              ) : null}
            </Box>
          )
        })}
        {hidden > 0 ? <Text dimColor>{`  +${hidden} more waiting in AgentBar`}</Text> : null}
      </Box>
    )
  })
}

type Attention = { sessions?: AgentBarWaiting[]; jump_shortcut?: string | null }

/** What the session waits on, as the row reads it. */
function ask(status: string): string {
  if (status === 'permission') return 'needs permission'
  if (status === 'question') return 'has a question'
  return 'needs you'
}

/** Permission prompts in yellow, as the menu bar draws them; questions in cyan. */
function tone(status: string): string {
  return status === 'permission' ? 'yellow' : 'cyan'
}

/** How long a session has waited, coarse on purpose: `now`, `4m`, `2h`. */
function ago(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return ''
  if (seconds < 60) return 'now'
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
  return `${Math.floor(seconds / 3600)}h`
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
  // The clock the waiting times are read against, written only when a time the band
  // shows would change, so the band redraws about once a minute rather than every poll.
  const now = await safe(async () => Math.floor((await $.clock.now()) / 1000))
  const shown = await read($, clockSeconds)
  if (now !== undefined && ages(others, now) !== ages(others, shown)) {
    await update($, clockSeconds, () => now)
  }
}

function ages(entries: AgentBarWaiting[], now: number): string {
  return entries.map(entry => (now ? ago(now - entry.waiting_since) : '')).join(',')
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
 * Posts an answerable prompt to AgentBar and waits for an answer from the menu bar.
 * Resolves `undefined` when there is none to take: AgentBar is down (the event is then
 * forwarded the usual way, which launches it), answering is turned off, the prompt was
 * answered in the terminal or cleared, or the dispatch ended. Never throws.
 */
async function offer(
  $: $,
  endpoint: string,
  body: object | (() => Promise<object>),
  signal: AbortSignal,
  settled: () => boolean = () => false,
): Promise<Answer | undefined> {
  // No launching here: the launch wait sleeps, and sleeps count against the hook's budget.
  const target = await connect($, { launch: false })
  if (!target) return forward($, endpoint, body), undefined

  const id = answerId()
  const base = `http://127.0.0.1:${target.port}`
  const auth = { Authorization: `Bearer ${target.token}` }
  let open = false
  try {
    const payload = typeof body === 'function' ? await body() : body
    const offered = await $.http.fetch(`${base}/v1/${endpoint}`, {
      method: 'POST',
      headers: { ...(await headers($)), ...auth, 'X-AgentBar-Answer-Id': id },
      body: JSON.stringify(payload),
    })
    open = offered.ok && parse(offered.text)?.answerable === true
    if (!open) return undefined

    const deadline = (await $.clock.now()) + MAX_WAIT_MS
    while (!signal.aborted && !settled() && (await $.clock.now()) < deadline) {
      const polled = await $.http.fetch(`${base}/v1/answer/${id}?wait=${ANSWER_POLL_MS}`, { headers: auth })
      if (polled.status === 204) continue
      // 410: answered in the terminal, dismissed or superseded. Anything else: give up.
      open = false
      return polled.status === 200 ? toAnswer(parse(polled.text)) : undefined
    }
    return undefined
  } catch {
    return undefined
  } finally {
    // Stopped waiting with the question still open: tell AgentBar to drop the buttons so
    // the row goes back to notify-only.
    if (open) {
      void $.http.fetch(`${base}/v1/answer/${id}`, { method: 'DELETE', headers: auth }).catch(() => {})
    }
  }
}

function toAnswer(raw: Record<string, unknown> | undefined): Answer | undefined {
  if (raw?.behavior === 'allow') return { behavior: 'allow' }
  if (raw?.behavior === 'deny') {
    return { behavior: 'deny', message: typeof raw.message === 'string' ? raw.message : undefined }
  }
  const answers = raw?.answers
  if (answers && typeof answers === 'object' && !Array.isArray(answers)) {
    const picked = Object.entries(answers).filter(([, v]) => typeof v === 'string')
    if (picked.length > 0) return { answers: Object.fromEntries(picked) as Record<string, string> }
  }
  return undefined
}

function parse(text: string): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(text)
    return value && typeof value === 'object' ? (value as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

/** A fresh id tying one prompt to its answer; not a secret (the bearer token guards it). */
function answerId(): string {
  let id = ''
  for (let i = 0; i < 24; i++) id += Math.floor(Math.random() * 16).toString(16)
  return id
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
