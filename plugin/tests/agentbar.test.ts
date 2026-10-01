import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { HttpInit, On } from 'claude-code'

const HOME = '/Users/tester'
const SERVER_FILE = `${HOME}/Library/Application Support/AgentBar/server.json`

type Post = { url: string; init: HttpInit | undefined; body: Record<string, unknown> }

type World = {
  /** Whether the app is answering; flipped by `open` when `launches` is set. */
  running: boolean
  /** Whether `open -g -b …` succeeds and brings the app up. */
  launches: boolean
  /** Whether server.json exists. */
  published: boolean
  /** Whether "Answer prompts from the menu bar" is on in the app. */
  answering?: boolean
  /**
   * What the app answers a poll with once `answerAfter` polls have gone by: an answer body
   * (200), `'gone'` (410: answered in the terminal or cleared), or nothing yet (204).
   */
  answer?: Record<string, unknown> | 'gone'
  answerAfter?: number
  /** What the settings hooks beneath answer a permission request with. */
  settingsDecision?: Record<string, unknown>
  /** What `GET /v1/attention` answers: the sessions waiting on you, and the jump hotkey. */
  attention?: { sessions: Waiting[]; jump_shortcut: string | null }
}

type Waiting = { session_id: string; cwd: string; status: string; summary: string; waiting_since: number }

/**
 * Stands in for the machine beneath the mod: the environment, server.json, AgentBar's
 * server, `open`, and the session's model and usage. Returns the posts AgentBar received
 * and the `open` commands run.
 */
function machine(on: On, port: number, world: World, { clock = true }: { clock?: boolean } = {}) {
  const posts: Post[] = []
  const opened: string[][] = []
  const answerPolls: string[] = []
  const withdrawn: string[] = []
  let polls = 0
  let arrived: (() => void) | undefined
  const waitForPost = () =>
    new Promise<void>(resolve => {
      if (posts.length > 0) resolve()
      else arrived = resolve
    })

  mock.env(on, { HOME, TERM_PROGRAM: 'iTerm.app' })
  on('fs.read', async ($, e, next) => {
    if (e.path !== SERVER_FILE) return next(e)
    if (!world.published) return { deny: 'ENOENT' }
    return { value: JSON.stringify({ port, pid: 1, version: 'test', token: 'secret' }) }
  })
  on('http.fetch', async ($, e) => {
    const authorized = e.init?.headers?.Authorization === 'Bearer secret'
    const ours = e.url.startsWith(`http://127.0.0.1:${port}/`)
    if (!world.running || !ours) return { deny: 'ECONNREFUSED' }
    if (!authorized) return { value: { status: 401, ok: false, headers: {}, text: 'unauthorized' } }
    if (e.url.endsWith('/v1/health')) return { value: { status: 200, ok: true, headers: {}, text: '{"ok":true}' } }
    const answerPath = e.url.match(/\/v1\/answer\/([0-9a-f]+)/)
    if (answerPath) {
      const id = answerPath[1] ?? ''
      if (e.init?.method === 'DELETE') {
        withdrawn.push(id)
        return { value: { status: 204, ok: true, headers: {}, text: '' } }
      }
      answerPolls.push(id)
      if (answerPolls.length <= (world.answerAfter ?? 0) || world.answer === undefined) {
        return { value: { status: 204, ok: true, headers: {}, text: '' } }
      }
      if (world.answer === 'gone') return { value: { status: 410, ok: false, headers: {}, text: '' } }
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(world.answer) } }
    }
    if (e.url.endsWith('/v1/attention')) {
      polls += 1
      const text = JSON.stringify(world.attention ?? { sessions: [], jump_shortcut: null })
      return { value: { status: 200, ok: true, headers: {}, text } }
    }
    posts.push({ url: e.url, init: e.init, body: JSON.parse(e.init?.body ?? '{}') })
    arrived?.()
    if (e.init?.headers?.['X-AgentBar-Answer-Id']) {
      const text = JSON.stringify({ answerable: world.answering === true })
      return { value: { status: 200, ok: true, headers: {}, text } }
    }
    return { value: { status: 204, ok: true, headers: {}, text: '' } }
  })
  on('process.run', async ($, e) => {
    opened.push([...e.argv])
    const ran = { stdout: '', isStdoutTruncated: false, isStderrTruncated: false }
    if (!world.launches) return { value: { ...ran, exitCode: 1, stderr: 'not installed' } }
    world.running = true
    world.published = true
    return { value: { ...ran, exitCode: 0, stderr: '' } }
  })
  on('session.id', async () => ({ value: 'session-1' }))
  on('session.cwd', async () => ({ value: '/work/project' }))
  on('session.model', async () => ({ value: 'claude-opus-5-5' }))
  // The launch wait polls with sleeps; answer them at once (unless the test keeps a clock).
  if (clock) {
    on('clock.sleep', async () => ({ value: undefined }))
    on('clock.now', async () => ({ value: 1_000 }))
  }
  on('session.usage', async () => ({
    value: { startedAt: 0, context: { tokens: 123_456, window: 1_000_000, percent: 12 }, rateLimits: [] },
  }))

  // Nothing beneath the plugins answers a classic event in a test; these stand in for the
  // engine's own (no settings hooks configured).
  on('classic.PermissionRequest', async () =>
    world.settingsDecision ? ({ decision: world.settingsDecision } as never) : {},
  )
  on('classic.Notification', async () => ({}))

  // The engine's own session start and band (an empty one), beneath the mod's.
  on('session.start', async ($, e) => ({ cwd: e.cwd }))
  on('ui.render', { component: 'AbovePrompt' }, async () => ({ type: 'Box', props: {}, children: [] }) as never)

  return { posts, opened, waitForPost, polls: () => polls, answerPolls, withdrawn }
}

describe('forwarding', () => {
  test('a permission request reaches /v1/permission with the hook input and the extras', async ($, on) => {
    const app = machine(on, 41001, { running: true, launches: false, published: true })

    await $.classic.PermissionRequest({
      tool_name: 'Bash',
      tool_input: { command: 'rm -rf build' },
    } as never)
    await app.waitForPost()

    const [post] = app.posts
    expect(post?.url).toBe('http://127.0.0.1:41001/v1/permission')
    expect(post?.body.hook_event_name).toBe('PermissionRequest')
    expect(post?.body.tool_name).toBe('Bash')
    expect(post?.body.tool_input).toEqual({ command: 'rm -rf build' })
    expect(post?.init?.headers).toEqual(
      expect.objectContaining({
        Authorization: 'Bearer secret',
        'X-AgentBar-Agent': 'claude',
        'X-AgentBar-Bridge': 'mod',
        'X-AgentBar-Term': 'iTerm.app',
        'X-AgentBar-Model': 'claude-opus-5-5',
        'X-AgentBar-Context-Tokens': '123456',
        'X-AgentBar-Context-Window': '1000000',
      }),
    )
  })

  test('a finished turn reaches /v1/stop', async ($, on) => {
    const app = machine(on, 41002, { running: true, launches: false, published: true })
    on('classic.Stop', async () => ({}))

    await $.classic.Stop({ stop_hook_active: false } as never)
    await app.waitForPost()

    expect(app.posts.map(p => p.url)).toEqual(['http://127.0.0.1:41002/v1/stop'])
  })

  test('an AskUserQuestion is forwarded as a PreToolUse ask before it is answered', async ($, on) => {
    const app = machine(on, 41003, { running: true, launches: false, published: true })
    let answered = false
    on('tool.call', { tool: 'AskUserQuestion' }, async () => {
      // Stands in for the person answering in the terminal, after AgentBar heard about it.
      await app.waitForPost()
      answered = true
      return { result: { answers: { 'Ship it?': 'Yes' } } } as never
    })

    const questions = [
      { question: 'Ship it?', header: 'Ship', options: [{ label: 'Yes', description: '' }], multiSelect: false },
    ]
    await $.tool.call({ tool: 'AskUserQuestion', questions } as never)

    expect(answered).toBe(true)
    const [post] = app.posts
    expect(post?.url).toBe('http://127.0.0.1:41003/v1/ask')
    expect(post?.body.hook_event_name).toBe('PreToolUse')
    expect(post?.body.tool_name).toBe('AskUserQuestion')
    expect(post?.body.session_id).toBe('session-1')
    expect(post?.body.cwd).toBe('/work/project')
    expect(post?.body.tool_input).toEqual(expect.objectContaining({ questions }))
  })
})

describe('launching and failing open', () => {
  test('when AgentBar is not running, the mod opens it and then delivers the event', async ($, on) => {
    const app = machine(on, 41004, { running: false, launches: true, published: false })

    await $.classic.Notification({ message: 'Claude is waiting for your input' } as never)
    await app.waitForPost()

    expect(app.opened).toEqual([['open', '-g', '-b', 'com.jreed91.AgentBar']])
    expect(app.posts.map(p => p.url)).toEqual(['http://127.0.0.1:41004/v1/notify'])
  })

  test('when AgentBar is missing, the event passes through untouched and nothing is posted', async ($, on) => {
    const app = machine(on, 41005, { running: false, launches: false, published: false })
    let reachedBottom = false
    on('classic.Stop', async () => {
      reachedBottom = true
      return {}
    })

    const result = await $.classic.Stop({ stop_hook_active: false } as never)

    expect(reachedBottom).toBe(true)
    expect(result).toEqual({})
    expect(app.posts).toEqual([])
  })
})

describe('answering from the menu bar', () => {
  const bash = { tool_name: 'Bash', tool_input: { command: 'npm publish' } } as never

  test('an allow picked in the menu bar answers the permission request', async ($, on) => {
    const app = machine(on, 41101, { running: true, launches: false, published: true, answering: true, answer: { behavior: 'allow' }, answerAfter: 2 })

    const result = await $.classic.PermissionRequest(bash)

    expect(result.decision).toEqual({ behavior: 'allow' })
    expect(app.posts[0]?.init?.headers?.['X-AgentBar-Answer-Id']).toMatch(/^[0-9a-f]{24}$/)
    expect(app.answerPolls.length).toBe(3)
    expect(app.withdrawn).toEqual([])
  })

  test('a deny picked in the menu bar refuses the request with its message', async ($, on) => {
    machine(on, 41102, { running: true, launches: false, published: true, answering: true, answer: { behavior: 'deny' } })

    const result = await $.classic.PermissionRequest(bash)

    expect(result.decision).toEqual({ behavior: 'deny', message: 'Denied from the AgentBar menu bar.' })
  })

  test('with answering turned off, the request is only forwarded and the terminal decides', async ($, on) => {
    const app = machine(on, 41103, { running: true, launches: false, published: true, answering: false, answer: { behavior: 'allow' } })

    const result = await $.classic.PermissionRequest(bash)

    expect(result).toEqual({})
    expect(app.posts.map(p => p.url)).toEqual(['http://127.0.0.1:41103/v1/permission'])
    expect(app.answerPolls).toEqual([])
  })

  test('a prompt answered in the terminal first leaves the decision to the terminal', async ($, on) => {
    const app = machine(on, 41104, { running: true, launches: false, published: true, answering: true, answer: 'gone', answerAfter: 1 })

    const result = await $.classic.PermissionRequest(bash)

    expect(result).toEqual({})
    expect(app.answerPolls.length).toBe(2)
    expect(app.withdrawn).toEqual([])
  })

  test('a settings hook that already decided is not offered to the menu bar', async ($, on) => {
    const app = machine(on, 41105, {
      running: true, launches: false, published: true, answering: true, answer: { behavior: 'deny' },
      settingsDecision: { behavior: 'allow' },
    })

    const result = await $.classic.PermissionRequest(bash)
    await app.waitForPost()

    expect(result.decision).toEqual({ behavior: 'allow' })
    expect(app.answerPolls).toEqual([])
  })

  const questions = [
    { question: 'Which database?', header: 'DB', options: [{ label: 'Postgres', description: '' }, { label: 'SQLite', description: '' }], multiSelect: false },
  ]

  test('an option picked in the menu bar answers AskUserQuestion and closes the terminal dialog', async ($, on) => {
    machine(on, 41106, { running: true, launches: false, published: true, answering: true, answer: { answers: { 'Which database?': 'SQLite' } } })
    let terminalClosed = false
    on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
      // The terminal dialog: open until someone answers or the call is taken away.
      await new Promise<void>(resolve => next.signal.addEventListener('abort', () => resolve()))
      terminalClosed = true
      return { result: { questions, answers: {} } } as never
    })

    const result = await $.tool.call({ tool: 'AskUserQuestion', questions } as never)

    expect(result).toEqual(expect.objectContaining({ result: { questions, answers: { 'Which database?': 'SQLite' } } }))
    expect(terminalClosed).toBe(true)
  })

  test('an AskUserQuestion answered in the terminal first keeps the terminal answer', async ($, on) => {
    const app = machine(on, 41107, { running: true, launches: false, published: true, answering: true })
    on('tool.call', { tool: 'AskUserQuestion' }, async () => {
      await app.waitForPost()
      return { result: { questions, answers: { 'Which database?': 'Postgres' } } } as never
    })

    const result = await $.tool.call({ tool: 'AskUserQuestion', questions } as never)

    expect(result).toEqual(expect.objectContaining({ result: { questions, answers: { 'Which database?': 'Postgres' } } }))
  })
})

describe('the band above the prompt', () => {
  const BAND = {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 9 },
    view: {},
  }
  const waitingOn = (session_id: string, cwd: string, status: string): Waiting => ({
    session_id,
    cwd,
    status,
    summary: 'Wants to run Bash',
    waiting_since: 1_700_000_000,
  })
  const startSession = ($: Engine, isInteractive = true) =>
    $.session.start({ cwd: '/work/project', surface: isInteractive ? 'terminal' : null, isInteractive })

  for (const surface of ['terminal', 'desktop'] as const) {
    test(`on ${surface}, it gives each other session waiting a row, never this one, and Jump focuses that row's`, async ($, on) => {
      const app = machine(on, 41101, {
        running: true,
        launches: false,
        published: true,
        attention: {
          sessions: [
            waitingOn('session-2', '/work/api', 'permission'),
            waitingOn('session-1', '/work/project', 'question'),
            { ...waitingOn('session-3', '/work/web', 'question'), summary: 'Which database?' },
          ],
          jump_shortcut: '⌥⇧A',
        },
      }, { clock: false })
      mock.clock(on, { now: (1_700_000_000 + 5 * 60) * 1000 })
      await startSession($)

      const ui = await $.ui.mount({ plugin: 'agentbar', surface, component: 'AbovePrompt', props: BAND })
      const drawn = JSON.stringify(await ui.drawn())
      expect(drawn).toContain('needs permission')
      expect(drawn).toContain(' · Wants to run Bash')
      expect(drawn).toContain('has a question')
      expect(drawn).toContain(' · Which database?')
      expect(drawn).toContain('"5m"')
      expect(drawn).toContain('api')
      expect(drawn).toContain('web')
      expect(drawn).not.toContain('project')
      expect(drawn).toContain('or ⌥⇧A')

      await ui.press({ key: 'jump-session-3' })
      const focus = app.posts.find(p => p.url.endsWith('/v1/focus'))
      expect(focus?.body).toEqual({ session_id: 'session-3' })
    })
  }

  test('it shows three rows and folds the rest', async ($, on) => {
    machine(on, 41106, {
      running: true,
      launches: false,
      published: true,
      attention: {
        sessions: ['a', 'b', 'c', 'd', 'e'].map(name => waitingOn(`s-${name}`, `/work/${name}`, 'question')),
        jump_shortcut: null,
      },
    }, { clock: false })
    mock.clock(on)
    await startSession($)

    const ui = await $.ui.mount({ plugin: 'agentbar', surface: 'terminal', component: 'AbovePrompt', props: BAND })
    expect(await ui.find({ key: 'jump-s-c' })).toBeDefined()
    expect(await ui.find({ key: 'jump-s-d' })).toBeUndefined()
    expect(JSON.stringify(await ui.drawn())).toContain('+2 more waiting in AgentBar')
  })

  test('the waiting time keeps up without a redraw every poll', async ($, on) => {
    machine(on, 41107, {
      running: true,
      launches: false,
      published: true,
      attention: { sessions: [waitingOn('session-2', '/work/api', 'permission')], jump_shortcut: null },
    }, { clock: false })
    const clock = mock.clock(on, { now: (1_700_000_000 + 30) * 1000 })
    await startSession($)
    await clock.settle()

    const ui = await $.ui.mount({ plugin: 'agentbar', surface: 'terminal', component: 'AbovePrompt', props: BAND })
    expect(JSON.stringify(await ui.drawn())).toContain('"now"')
    await clock.advance(2 * 60 * 1000)
    expect(JSON.stringify(await ui.drawn())).toContain('"2m"')
  })

  test('it follows AgentBar as sessions start and stop waiting', async ($, on) => {
    const world: World = { running: true, launches: false, published: true }
    machine(on, 41102, world, { clock: false })
    const clock = mock.clock(on)
    await startSession($)
    await clock.settle()

    const ui = await $.ui.mount({ plugin: 'agentbar', surface: 'terminal', component: 'AbovePrompt', props: BAND })
    expect(await ui.find({ text: /needs permission/ })).toBeUndefined()

    world.attention = { sessions: [waitingOn('session-2', '/work/api', 'permission')], jump_shortcut: null }
    await clock.advance(2000)
    expect(JSON.stringify(await ui.drawn())).toContain('needs permission')

    world.attention = { sessions: [], jump_shortcut: null }
    await clock.advance(2000)
    expect(await ui.find({ text: /needs permission/ })).toBeUndefined()
  })

  test('a narrow terminal keeps the ask and drops the summary and the hotkey', async ($, on) => {
    const app = machine(on, 41103, {
      running: true,
      launches: false,
      published: true,
      attention: { sessions: [waitingOn('session-2', '/work/api', 'permission')], jump_shortcut: '⌥⇧A' },
    }, { clock: false })
    mock.clock(on)
    await startSession($)

    const ui = await $.ui.mount({
      plugin: 'agentbar',
      surface: 'terminal',
      component: 'AbovePrompt',
      props: { ...BAND, bodyColumns: 50 },
    })
    const drawn = JSON.stringify(await ui.drawn())
    expect(drawn).toContain('needs permission')
    expect(drawn).not.toContain('Wants to run Bash')
    expect(drawn).not.toContain('⌥⇧A')

    await ui.press({ key: 'jump-session-2' })
    expect(app.posts.find(p => p.url.endsWith('/v1/focus'))?.body).toEqual({ session_id: 'session-2' })
  })

  test('a poll never launches AgentBar, and with the app down the band stays hidden', async ($, on) => {
    const app = machine(on, 41104, { running: false, launches: true, published: false }, { clock: false })
    const clock = mock.clock(on)
    await startSession($)
    await clock.advance(10_000)

    const ui = await $.ui.mount({ plugin: 'agentbar', surface: 'terminal', component: 'AbovePrompt', props: BAND })
    expect(await ui.find({ text: /needs permission|has a question/ })).toBeUndefined()
    expect(app.opened).toEqual([])
  })

  test('a non-interactive run never polls', async ($, on) => {
    const app = machine(on, 41105, { running: true, launches: false, published: true }, { clock: false })
    const clock = mock.clock(on)
    await startSession($, false)
    await clock.advance(10_000)

    expect(app.polls()).toBe(0)
    expect(app.posts).toEqual([])
  })
})
