import { useCallback, useEffect, useRef, useState } from 'react'
import { Channel, type ChannelState } from './channel'
import { fromBase64URL } from './crypto'
import { useDemo, isDemo } from './demo'
import type { Account, ChatItem, Issue, Key, Repo, Screen, Session, StepKind } from './protocol'

const SECRET_KEY = 'muxy.secret'
const ROOM_KEY = 'muxy.room'
const SENT_KEY = 'muxy.sent'

/** Commands sent from this phone, newest first — history until Muxy sends its own. */
function readSent(): string[] {
  try {
    return JSON.parse(localStorage.getItem(SENT_KEY) ?? '[]')
  } catch {
    return []
  }
}

type Pairing = { secret: string; room: string | null }

function store(key: string, value: string | null) {
  try {
    if (value === null) localStorage.removeItem(key)
    else localStorage.setItem(key, value)
  } catch {
    /* private mode: works for this visit only */
  }
}

/** Started from the home screen rather than a Safari tab. */
function standalone() {
  return matchMedia('(display-mode: standalone)').matches || (navigator as { standalone?: boolean }).standalone === true
}

/**
 * The pairing arrives in the QR code's fragment (#r=room&k=secret) —
 * browsers never send a fragment to a server. iOS gives a home-screen app
 * its own storage, separate from Safari's, and "Add to Home Screen" saves
 * the current address: so in a Safari tab the pairing stays in the
 * address, and the home-screen app picks it up from there on its first
 * start. Only there, where there is no address bar, it is wiped.
 */
function readPairing(): Pairing | null {
  let pairing: Pairing | null = null
  const secret = location.hash.match(/k=([A-Za-z0-9_-]{43})/)?.[1]
  if (secret) {
    pairing = { secret, room: location.hash.match(/r=([0-9a-f]{32})/)?.[1] ?? null }
    store(SECRET_KEY, pairing.secret)
    store(ROOM_KEY, pairing.room)
  } else {
    try {
      const stored = localStorage.getItem(SECRET_KEY)
      if (stored) pairing = { secret: stored, room: localStorage.getItem(ROOM_KEY) }
    } catch {
      /* no storage */
    }
  }
  if (standalone()) {
    if (location.hash) history.replaceState(null, '', location.pathname)
  } else if (pairing && !secret) {
    // Opened without the link: put it back, so adding to the home screen works.
    history.replaceState(null, '', `${location.pathname}#${pairing.room ? `r=${pairing.room}&` : ''}k=${pairing.secret}`)
  }
  return pairing
}

function channelURL(room: string | null) {
  if (room) return `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/relay/phone/${room}`
  // Served by Muxy: the channel is the next port. `pnpm dev`: Muxy's default.
  const port = import.meta.env.DEV ? 47821 : Number(location.port || 80) + 1
  return `ws://${location.hostname}:${port}/`
}

export function forgetPairing() {
  store(SECRET_KEY, null)
  store(ROOM_KEY, null)
}

/** Muxy before 0.4 knew only Claude: its agent tabs came as "claude". */
function compatible(s: Session): Session {
  const tabs = s.tabs.map((t) => ((t.kind as string) === 'claude' ? { ...t, kind: 'agent' as const, agentKind: t.agentKind ?? ('claude' as const) } : t))
  const agentKind = s.agentKind ?? tabs.find((t) => t.kind === 'agent')?.agentKind
  return { ...s, tabs, agentKind }
}

function useChannel() {
  const [pairing] = useState(readPairing)
  const [state, setState] = useState<ChannelState>('connecting')
  const [sessions, setSessions] = useState<Session[]>([])
  const [recent, setRecent] = useState<string[]>([])
  const [shellHistory, setShellHistory] = useState<string[]>([])
  const [sent, setSent] = useState<string[]>(readSent)
  const [screens, setScreens] = useState<Record<string, Screen>>({})
  const [chats, setChats] = useState<Record<string, ChatItem[]>>({})
  const [repos, setRepos] = useState<Repo[]>([])
  const [issues, setIssues] = useState<Issue[]>([])
  const [account, setAccount] = useState<Account | null>(null)
  const [opened, setOpened] = useState<{ session: string | null; error?: string; at: number } | null>(null)
  const channel = useRef<Channel | null>(null)
  const pendingInput = useRef(new Map<string, (accepted: boolean) => void>())
  const inputSequence = useRef(0)
  const inputOrder = useRef<string[]>([])
  const watching = useRef<{ tab: string; history: boolean } | null>(null)

  useEffect(() => {
    if (!pairing) return
    const url = channelURL(pairing.room)
    const c = new Channel(
      url,
      fromBase64URL(pairing.secret),
      (m) => {
        switch (m.t) {
          case 'sessions':
            setSessions((m.sessions as Session[]).map(compatible))
            setRecent(m.recent as string[])
            if (Array.isArray(m.history)) setShellHistory(m.history as string[])
            if (Array.isArray(m.issues)) setIssues(m.issues as Issue[])
            setAccount((m.account as Account) ?? null)
            break
          case 'screen':
            setScreens((s) => ({ ...s, [m.tab as string]: m as unknown as Screen }))
            break
          case 'chat':
            setChats((s) => ({
              ...s,
              // Muxy before 0.4 called the agent's messages "claude".
              [m.tab as string]: (m.items as ChatItem[]).map((i) => ((i.kind as string) === 'claude' ? { ...i, kind: 'agent' } : i) as ChatItem),
            }))
            break
          case 'typed': {
            // Older Macs acknowledge in send order without an id. Keep timed-out
            // requests in that order so a late reply cannot confirm a newer send.
            const request = typeof m.request === 'string' ? m.request : inputOrder.current[0]
            if (request) {
              inputOrder.current = inputOrder.current.filter((id) => id !== request)
              pendingInput.current.get(request)?.(m.ok === true)
            }
            break
          }
          case 'opened':
            setOpened({ session: (m.session as string) ?? null, error: (m.error as string) ?? undefined, at: Date.now() })
            break
          case 'repos':
            setRepos(m.repos as Repo[])
            break
        }
      },
      (s) => {
        setState(s)
        if (s !== 'open') {
          inputOrder.current = []
          for (const finish of pendingInput.current.values()) finish(false)
        }
        // After a reconnect, tell muxy again what we're looking at.
        if (s === 'open' && watching.current) c.send({ t: 'watch', ...watching.current })
      },
    )
    channel.current = c
    c.start()
    return () => {
      inputOrder.current = []
      for (const finish of pendingInput.current.values()) finish(false)
      c.stop()
    }
  }, [pairing])

  const watch = useCallback((tab: string | null, withHistory = false) => {
    watching.current = tab ? { tab, history: withHistory } : null
    channel.current?.send({ t: 'watch', tab, history: withHistory })
  }, [])

  const type = useCallback(async (tab: string, text: string, enter = true) => {
    const request = `${Date.now()}-${++inputSequence.current}`
    const accepted = await new Promise<boolean>((resolve) => {
      const finish = (ok: boolean) => {
        clearTimeout(timeout)
        pendingInput.current.delete(request)
        resolve(ok)
      }
      const timeout = window.setTimeout(() => finish(false), 10000)
      pendingInput.current.set(request, finish)
      inputOrder.current.push(request)
      if (!channel.current?.send({ t: 'type', tab, text, enter, request })) {
        inputOrder.current = inputOrder.current.filter((id) => id !== request)
        finish(false)
      }
    })
    if (!accepted) return false
    const line = text.trim()
    if (enter && line && !line.includes('\n')) {
      setSent((list) => {
        const next = [line, ...list.filter((c) => c !== line)].slice(0, 40)
        store(SENT_KEY, JSON.stringify(next))
        return next
      })
    }
    return true
  }, [])

  // Newest first: what this phone sent, then the shell's own history.
  const history = [...new Set([...sent, ...shellHistory])]

  const key = useCallback((tab: string, k: Key | string) => {
    return channel.current?.send({ t: 'key', tab, key: k }) ?? false
  }, [])

  const choose = useCallback((tab: string, number: number) => {
    channel.current?.send({ t: 'choose', tab, number })
  }, [])

  const loadRepos = useCallback(() => {
    channel.current?.send({ t: 'repos' })
  }, [])

  const start = useCallback((spec: NewSession) => {
    channel.current?.send({ t: 'new', ...spec })
  }, [])

  /** Takes the session's suggested next step, if it still is that one. */
  const step = useCallback((session: string, kind: StepKind) => {
    channel.current?.send({ t: 'step', session, kind })
  }, [])

  /** An assigned issue becomes a session on the Mac (answered with "opened"). */
  const startIssue = useCallback((issue: Issue, agents: ('claude' | 'codex')[]) => {
    channel.current?.send({ t: 'issue', repo: issue.repo, number: issue.number, agents })
  }, [])

  return {
    paired: !!pairing,
    state,
    sessions,
    recent,
    repos,
    history,
    screens,
    chats,
    opened,
    watch,
    type,
    key,
    choose,
    loadRepos,
    start,
    issues,
    account,
    step,
    startIssue,
  }
}

/** What the phone asks for when it starts a session (like ⌘N). */
export type NewSession = { directory: string; agent: 'claude' | 'codex' | 'none'; prompt: string; worktree: boolean }

export type Muxy = ReturnType<typeof useChannel>

/** `pnpm dev` with #demo: made-up sessions, nothing sent anywhere. */
export const useMuxy: () => Muxy = isDemo ? useDemo : useChannel
