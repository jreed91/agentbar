import { describe, expect, mock, test } from 'claude-code/testing'
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
}

/**
 * Stands in for the machine beneath the mod: the environment, server.json, AgentBar's
 * server, `open`, and the session's model and usage. Returns the posts AgentBar received
 * and the `open` commands run.
 */
function machine(on: On, port: number, world: World) {
  const posts: Post[] = []
  const opened: string[][] = []
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
    posts.push({ url: e.url, init: e.init, body: JSON.parse(e.init?.body ?? '{}') })
    arrived?.()
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
  // The launch wait polls with sleeps; answer them at once.
  on('clock.sleep', async () => ({ value: undefined }))
  on('session.usage', async () => ({
    value: { startedAt: 0, context: { tokens: 123_456, window: 1_000_000, percent: 12 }, rateLimits: [] },
  }))

  // Nothing beneath the plugins answers a classic event in a test; these stand in for the
  // engine's own (no settings hooks configured).
  on('classic.PermissionRequest', async () => ({}))
  on('classic.Notification', async () => ({}))

  return { posts, opened, waitForPost }
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
