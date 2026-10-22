// What Muxy sends (RemoteState.swift, Transcript.swift).

export type InputDelivery = 'accepted' | 'rejected' | 'partial' | 'unconfirmed'

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
  /** The tab selected on the Mac, including a Quorum log terminal. */
  selectedTab?: string
  branch?: string
  /** The tab running the agent (idle or at work): where messages go. */
  agentTab?: string
  /** What the session needs next, as the Mac's hub suggests it. */
  next?: { kind: StepKind; title: string }
  stage?: 'working' | 'review' | 'ready' | 'none'
  /** muxy's own checks on the session's files. */
  proof?: 'running' | 'passed' | 'failed'
  /** Sessions (or the base branch) its work would conflict with. */
  collisions?: string[]
  quorum?: { summary: string; running: boolean; clean: boolean }
}

export type StepKind = 'wait' | 'answer' | 'approvePlan' | 'openPR' | 'review' | 'fix' | 'land' | 'reviewing' | 'landing' | 'none'

/** Steps a tap takes; the others only say what is going on. */
export const actionable = (kind?: StepKind) => kind === 'approvePlan' || kind === 'openPR' || kind === 'review' || kind === 'fix' || kind === 'land'

/** An issue assigned to you that no session works on yet. */
export type Issue = {
  repo: string
  number: number
  title: string
  url: string
  labels: string[]
  /** Cloned on the Mac: it can start there. */
  local: boolean
  /** Seconds since 1970. */
  created?: number
}

export type Account = { login: string; name?: string; avatar?: string }

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
