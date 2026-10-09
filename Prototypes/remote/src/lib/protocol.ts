// What Muxy sends (RemoteState.swift, Transcript.swift).

export type Agent = 'none' | 'idle' | 'working' | 'blocked' | 'failed'

export type PRStatus = 'none' | 'running' | 'fixing' | 'failed' | 'conflicts' | 'draft' | 'waiting' | 'ready' | 'merged' | 'closed'

export type Tab = {
  id: string
  kind: 'claude' | 'shell'
  title: string
  agent: Agent
  attention: boolean
}

export type Session = {
  id: string
  group: string
  title: string
  subtitle: string
  directory: string
  isGit: boolean
  agent: Agent
  attention: boolean
  pr?: { number: number; status: PRStatus }
  tabs: Tab[]
}

export type DiffLine = { sign: '+' | '-' | ' '; text: string }

export type ChatItem =
  | { kind: 'user'; text: string }
  | { kind: 'claude'; text: string }
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
  | '1'
  | '2'
  | '3'
  | 'y'
  | 'n'
  | 'q'
  | `ctrl-${string}`
