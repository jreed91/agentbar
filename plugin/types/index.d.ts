// The values AgentBar's in-terminal band draws from, held in the session's `$.state`.

/** One other session waiting on you, as AgentBar's `GET /v1/attention` reports it. */
export type AgentBarWaiting = {
  session_id: string
  cwd: string
  /** `permission` or `question`. */
  status: string
  summary: string
  /** Seconds since 1970. */
  waiting_since: number
}

declare module 'claude-code' {
  interface PluginState {
    agentbar: {
      /** Other sessions waiting on you, longest-waiting first; empty when none or unknown. */
      waiting: AgentBarWaiting[]
      /** AgentBar's global "focus needs me" hotkey, as it labels it (`⌥⇧A`); null when unset. */
      jumpShortcut: string | null
      /** The time the band reads waiting times against, in seconds since 1970; 0 until known. */
      now: number
    }
  }
}
