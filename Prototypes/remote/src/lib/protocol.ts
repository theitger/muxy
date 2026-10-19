// What Muxy sends (RemoteState.swift, Transcript.swift).

export type Agent = 'none' | 'idle' | 'working' | 'blocked' | 'failed'

export type AgentKind = 'claude' | 'codex'

export type PRStatus = 'none' | 'running' | 'fixing' | 'failed' | 'conflicts' | 'draft' | 'waiting' | 'ready' | 'merged' | 'closed'

/** A question the agent shows on screen, numbered as it draws it. */
export type Choice = { number: number; label: string; selected: boolean }

export type Tab = {
  id: string
  kind: 'agent' | 'shell'
  agentKind?: AgentKind
  title: string
  agent: Agent
  attention: boolean
  /** Seconds since 1970: since when it waits on you. */
  since?: number
  choices?: Choice[]
}

export type Session = {
  id: string
  group: string
  title: string
  subtitle: string
  directory: string
  isGit: boolean
  agent: Agent
  agentKind?: AgentKind
  attention: boolean
  /** What the agent is doing right now ("Running tests"). */
  activity?: string
  /** The last lines of its output. */
  lines?: string[]
  notice?: string
  pr?: { number: number; status: PRStatus }
  tabs: Tab[]
}

export type Repo = { path: string; name: string }

export type DiffLine = { sign: '+' | '-' | ' '; text: string }

export type ChatItem =
  | { kind: 'user'; text: string }
  | { kind: 'agent'; text: string }
  | {
      kind: 'tool'
      id: string
      tool: string
      target: string
      output?: string[]
      diff?: DiffLine[]
      error?: boolean
      done?: boolean
    }

export type Screen = { text: string; columns: number; rows: number }

export type Key =
  | 'enter'
  | 'esc'
  | 'tab'
  | 'shift-tab'
  | 'up'
  | 'down'
  | 'left'
  | 'right'
  | 'ctrl-c'
  | 'ctrl-d'
  | 'ctrl-r'
  | 'backspace'
  | 'y'
  | 'n'
  | 'q'
  | `ctrl-${string}`
  | `${number}`

export const agentName = (kind?: AgentKind) => (kind === 'codex' ? 'Codex' : kind === 'claude' ? 'Claude' : 'Agent')
