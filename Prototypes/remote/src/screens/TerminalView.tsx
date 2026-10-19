import { ArrowDown } from 'lucide-react'
import { memo, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import { Composer } from '@/components/Composer'
import { Tap } from '@/components/touch'
import type { Key, Screen } from '@/lib/protocol'

export function stored(name: string, fallback: string) {
  try {
    return localStorage.getItem(name) ?? fallback
  } catch {
    return fallback
  }
}
export function store(name: string, value: string) {
  try {
    localStorage.setItem(name, value)
  } catch {
    /* not kept */
  }
}

/**
 * The tab's real screen as Muxy reads it from Ghostty (text only). Pinch
 * to change the size; it follows new output unless you scrolled up to
 * read, then an arrow brings you back. Only lines that changed redraw.
 */
export function TerminalView({
  screen,
  wrap,
  onType,
  onKey,
  busy,
  commands,
  composer = true,
}: {
  screen?: Screen
  wrap: boolean
  onType: (text: string, enter: boolean) => void
  onKey: (key: Key | string) => void
  busy?: boolean
  commands?: string[]
  /** Off where the chat has its own input below. */
  composer?: boolean
}) {
  const [size, setSize] = useState(() => Number(stored('muxy.fontSize', '12.5')))
  const [behind, setBehind] = useState(false)
  const scroller = useRef<HTMLDivElement>(null)
  const stick = useRef(true)
  const pinch = useRef<{ size: number } | null>(null)

  useLayoutEffect(() => {
    const el = scroller.current
    if (!el) return
    if (stick.current) el.scrollTop = el.scrollHeight
    else setBehind(true)
  }, [screen?.text, wrap, size])

  // Pinch with two fingers: Safari's gesture events carry the scale.
  useEffect(() => {
    const el = scroller.current
    if (!el) return
    const start = (e: Event) => {
      e.preventDefault()
      pinch.current = { size }
    }
    const change = (e: Event) => {
      e.preventDefault()
      const p = pinch.current
      if (!p) return
      const scale = (e as unknown as { scale: number }).scale
      setSize(Math.round(Math.min(20, Math.max(8, p.size * scale)) * 2) / 2)
    }
    const end = (e: Event) => {
      e.preventDefault()
      pinch.current = null
    }
    el.addEventListener('gesturestart', start)
    el.addEventListener('gesturechange', change)
    el.addEventListener('gestureend', end)
    return () => {
      el.removeEventListener('gesturestart', start)
      el.removeEventListener('gesturechange', change)
      el.removeEventListener('gestureend', end)
    }
  }, [size])

  useEffect(() => store('muxy.fontSize', String(size)), [size])

  const lines = screen ? (wrap ? tidy(screen.text) : screen.text).split('\n') : []

  return (
    <div className="flex min-h-0 flex-1 flex-col bg-bg">
      <div className="relative flex min-h-0 flex-1 flex-col">
      <div
        ref={scroller}
        onScroll={(e) => {
          const el = e.currentTarget
          const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40
          stick.current = atBottom
          if (atBottom) setBehind(false)
        }}
        className="selectable no-scrollbar flex-1 overflow-auto overscroll-contain px-3.5 pt-3 pb-4"
      >
        {screen ? (
          <div style={{ fontSize: size }} className={cn('font-mono leading-[1.38] text-term', wrap ? 'break-words whitespace-pre-wrap' : 'w-max whitespace-pre')}>
            {lines.map((line, i) => (
              <Line key={i} text={line} wrap={wrap} />
            ))}
          </div>
        ) : (
          <div className="mt-16 flex justify-center">
            <span className="size-5 animate-spin rounded-full border-2 border-t4 border-t-transparent" />
          </div>
        )}
      </div>

      {behind && (
        <div className="pointer-events-none absolute inset-x-0 bottom-3 z-10 flex justify-center">
          <Tap
            label="Zum Ende"
            onPress={() => {
              stick.current = true
              setBehind(false)
              scroller.current?.scrollTo({ top: scroller.current.scrollHeight, behavior: 'smooth' })
            }}
            className="fade-in pointer-events-auto size-9 rounded-full border border-hair bg-raised/95 text-t2 shadow-[0_4px_16px_rgb(0_0_0/0.14)] backdrop-blur"
          >
            <ArrowDown className="size-[18px]" strokeWidth={2.4} />
          </Tap>
        </div>
      )}
      </div>

      {composer && (
        <Composer
          terminal
          screen={screen?.text}
          busy={busy}
          history={commands}
          placeholder="Befehl"
          onType={(text, enter) => {
            stick.current = true
            onType(text, enter)
          }}
          onKey={(k) => {
            stick.current = true
            onKey(k)
          }}
        />
      )}
    </div>
  )
}

const Line = memo(function Line({ text, wrap }: { text: string; wrap: boolean }) {
  // A full-width rule (an agent's input box) would wrap into several lines
  // on a phone: drawn as one.
  if (wrap && /^\s*[─━═]{8,}\s*$/.test(text)) return <div className="my-[0.55em] border-t border-ansi-dim/45" />
  return <div>{text || ' '}</div>
})

/**
 * Wrapped on a narrow screen, right-aligned bits (the prompt's clock, a
 * TUI's right column) would land on a line of their own after a run of
 * spaces: pulled in instead.
 */
function tidy(text: string) {
  return text.replace(/ {6,}(\S[^\n]{0,24})$/gm, '  $1')
}
