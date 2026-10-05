import { useCallback, useEffect, useRef, useState } from 'react'
import { Channel, type ChannelState } from './channel'
import { fromBase64URL } from './crypto'
import type { ChatItem, Key, Screen, Session } from './protocol'

const SECRET_KEY = 'muxy.secret'

/**
 * The pairing secret arrives once in the QR code's fragment (#k=…); it is
 * kept in this browser and wiped from the address bar right away.
 */
function readSecret(): string | null {
  const match = location.hash.match(/k=([A-Za-z0-9_-]{43})/)
  if (match) {
    try {
      localStorage.setItem(SECRET_KEY, match[1])
    } catch {
      /* private mode: works for this visit only */
    }
    history.replaceState(null, '', location.pathname)
    return match[1]
  }
  try {
    return localStorage.getItem(SECRET_KEY)
  } catch {
    return null
  }
}

export function forgetPairing() {
  try {
    localStorage.removeItem(SECRET_KEY)
  } catch {
    /* nothing stored */
  }
}

export function useMuxy() {
  const [secret] = useState(readSecret)
  const [state, setState] = useState<ChannelState>('connecting')
  const [sessions, setSessions] = useState<Session[]>([])
  const [recent, setRecent] = useState<string[]>([])
  const [screens, setScreens] = useState<Record<string, Screen>>({})
  const [chats, setChats] = useState<Record<string, ChatItem[]>>({})
  const [opened, setOpened] = useState<{ session: string | null; at: number } | null>(null)
  const channel = useRef<Channel | null>(null)
  const watching = useRef<{ tab: string; history: boolean } | null>(null)

  useEffect(() => {
    if (!secret) return
    // Served by Muxy: the channel is the next port. `pnpm dev`: Muxy's default.
    const port = import.meta.env.DEV ? 47821 : Number(location.port || 80) + 1
    const url = `ws://${location.hostname}:${port}/`
    const c = new Channel(
      url,
      fromBase64URL(secret),
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
  }, [secret])

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

  return { paired: !!secret, state, sessions, recent, screens, chats, opened, watch, type, key, open }
}

export type Muxy = ReturnType<typeof useMuxy>
