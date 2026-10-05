import { useCallback, useEffect, useRef, useState } from 'react'
import { Channel, type ChannelState } from './channel'
import { fromBase64URL } from './crypto'
import type { ChatItem, Key, Screen, Session } from './protocol'

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

export function useMuxy() {
  const [pairing] = useState(readPairing)
  const [state, setState] = useState<ChannelState>('connecting')
  const [sessions, setSessions] = useState<Session[]>([])
  const [recent, setRecent] = useState<string[]>([])
  const [shellHistory, setShellHistory] = useState<string[]>([])
  const [sent, setSent] = useState<string[]>(readSent)
  const [screens, setScreens] = useState<Record<string, Screen>>({})
  const [chats, setChats] = useState<Record<string, ChatItem[]>>({})
  const [opened, setOpened] = useState<{ session: string | null; at: number } | null>(null)
  const channel = useRef<Channel | null>(null)
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
            setSessions(m.sessions as Session[])
            setRecent(m.recent as string[])
            if (Array.isArray(m.history)) setShellHistory(m.history as string[])
            break
          case 'screen':
            setScreens((s) => ({ ...s, [m.tab as string]: m as unknown as Screen }))
            break
          case 'chat':
            setChats((s) => ({ ...s, [m.tab as string]: m.items as ChatItem[] }))
            break
          case 'opened':
            setOpened({ session: (m.session as string) ?? null, at: Date.now() })
            break
        }
      },
      (s) => {
        setState(s)
        // After a reconnect, tell muxy again what we're looking at.
        if (s === 'open' && watching.current) c.send({ t: 'watch', ...watching.current })
      },
    )
    channel.current = c
    c.start()
    return () => c.stop()
  }, [pairing])

  const watch = useCallback((tab: string | null, withHistory = false) => {
    watching.current = tab ? { tab, history: withHistory } : null
    channel.current?.send({ t: 'watch', tab, history: withHistory })
  }, [])

  const type = useCallback((tab: string, text: string, enter = true) => {
    channel.current?.send({ t: 'type', tab, text, enter })
    const line = text.trim()
    if (enter && line && !line.includes('\n')) {
      setSent((list) => {
        const next = [line, ...list.filter((c) => c !== line)].slice(0, 40)
        store(SENT_KEY, JSON.stringify(next))
        return next
      })
    }
  }, [])

  // Newest first: what this phone sent, then the shell's own history.
  const history = [...new Set([...sent, ...shellHistory])]

  const key = useCallback((tab: string, k: Key | string) => {
    channel.current?.send({ t: 'key', tab, key: k })
  }, [])

  const open = useCallback((directory: string) => {
    channel.current?.send({ t: 'open', directory })
  }, [])

  return { paired: !!pairing, state, sessions, recent, history, screens, chats, opened, watch, type, key, open }
}

export type Muxy = ReturnType<typeof useMuxy>
