import { useCallback, useEffect, useRef, useState } from 'react'
import { Channel, type ChannelState } from './channel'
import { fromBase64URL } from './crypto'
import type { ChatItem, Key, Screen, Session } from './protocol'

const SECRET_KEY = 'muxy.secret'
const ROOM_KEY = 'muxy.room'

type Pairing = { secret: string; room: string | null }

function store(key: string, value: string | null) {
  try {
    if (value === null) localStorage.removeItem(key)
    else localStorage.setItem(key, value)
  } catch {
    /* private mode: works for this visit only */
  }
}

/**
 * The pairing arrives once in the QR code's fragment (#r=room&k=secret);
 * it is kept in this browser and wiped from the address bar right away.
 * With a room the phone goes through the relay serving this page,
 * without one straight to Muxy on the local network.
 */
function readPairing(): Pairing | null {
  const secret = location.hash.match(/k=([A-Za-z0-9_-]{43})/)?.[1]
  if (secret) {
    const room = location.hash.match(/r=([0-9a-f]{32})/)?.[1] ?? null
    store(SECRET_KEY, secret)
    store(ROOM_KEY, room)
    history.replaceState(null, '', location.pathname)
    return { secret, room }
  }
  try {
    const stored = localStorage.getItem(SECRET_KEY)
    return stored ? { secret: stored, room: localStorage.getItem(ROOM_KEY) } : null
  } catch {
    return null
  }
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
  }, [])

  const key = useCallback((tab: string, k: Key) => {
    channel.current?.send({ t: 'key', tab, key: k })
  }, [])

  const open = useCallback((directory: string) => {
    channel.current?.send({ t: 'open', directory })
  }, [])

  return { paired: !!pairing, state, sessions, recent, screens, chats, opened, watch, type, key, open }
}

export type Muxy = ReturnType<typeof useMuxy>
