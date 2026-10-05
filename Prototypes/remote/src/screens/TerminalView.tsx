import { ArrowDown, History, WrapText } from 'lucide-react'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import { Dock } from '@/components/Dock'
import { Tap } from '@/components/touch'
import type { Key, Screen } from '@/lib/protocol'

function stored(name: string, fallback: string) {
  try {
    return localStorage.getItem(name) ?? fallback
  } catch {
    return fallback
  }
}
function store(name: string, value: string) {
  try {
    localStorage.setItem(name, value)
  } catch {
    /* not kept */
  }
}

/**
 * The tab's real screen as Muxy reads it from Ghostty (text only for now).
 * Pinch to change the size; it follows new output unless you scrolled up
 * to read — then a pill brings you back.
 */
export function TerminalView({
  screen,
  history,
  onHistory,
  onType,
  onKey,
  busy,
}: {
  screen?: Screen
  history: boolean
  onHistory: (on: boolean) => void
  onType: (text: string, enter: boolean) => void
  onKey: (key: Key | string) => void
  busy?: boolean
}) {
  const [wrap, setWrap] = useState(() => stored('muxy.wrap', '1') === '1')
  const [size, setSize] = useState(() => Number(stored('muxy.fontSize', '12.5')))
  const [behind, setBehind] = useState(false)
  const scroller = useRef<HTMLDivElement>(null)
  const stick = useRef(true)
  const pinch = useRef<{ start: number; size: number } | null>(null)

  useLayoutEffect(() => {
    const el = scroller.current
    if (!el) return
    if (stick.current) el.scrollTop = el.scrollHeight
    else setBehind(true)
  }, [screen?.text, wrap, size])

  useEffect(() => {
    stick.current = true
    setBehind(false)
  }, [history])

  // Pinch with two fingers: Safari's gesture events carry the scale.
  useEffect(() => {
    const el = scroller.current
    if (!el) return
    const start = (e: Event) => {
      e.preventDefault()
      pinch.current = { start: 1, size }
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

  function toBottom() {
    const el = scroller.current
    if (!el) return
    stick.current = true
    setBehind(false)
    el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
  }

  return (
    <div className="relative flex min-h-0 flex-1 flex-col bg-bg">
      <div className="absolute top-2 right-3 z-10 flex gap-1">
        <Pill on={history} onPress={() => onHistory(!history)} label="Verlauf laden">
          <History className="size-3.5" />
        </Pill>
        <Pill
          on={wrap}
          onPress={() => {
            setWrap(!wrap)
            store('muxy.wrap', wrap ? '0' : '1')
          }}
          label="Zeilen umbrechen"
        >
          <WrapText className="size-3.5" />
        </Pill>
      </div>

      <div
        ref={scroller}
        onScroll={(e) => {
          const el = e.currentTarget
          const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40
          stick.current = atBottom
          if (atBottom) setBehind(false)
        }}
        className="flex-1 overflow-auto overscroll-contain px-4 pt-3 pb-4"
      >
        {screen ? (
          <div
            style={{ fontSize: size }}
            className={cn('font-mono leading-[1.38] text-term', wrap ? 'break-words whitespace-pre-wrap' : 'w-max whitespace-pre')}
          >
            {(wrap ? tidy(screen.text) : screen.text).split('\n').map((line, i) =>
              // A full-width rule (Claude's input box) would wrap into
              // several lines on a phone — draw it as one.
              wrap && /^\s*[─━═]{8,}\s*$/.test(line) ? (
                <div key={i} className="my-[0.55em] border-t border-ansi-dim/45" />
              ) : (
                <div key={i}>{line || ' '}</div>
              ),
            )}
          </div>
        ) : (
          <p className="mt-10 text-center text-[14px] text-t4">Lädt den Bildschirm …</p>
        )}
      </div>

      {behind && (
        <div className="pointer-events-none absolute inset-x-0 bottom-[calc(var(--dock-h,170px)+10px)] z-10 flex justify-center">
          <Tap
            onPress={toBottom}
            className="pointer-events-auto h-8 gap-1 rounded-full bg-t1 px-3 text-[13px] font-semibold text-bg shadow-lg"
          >
            <ArrowDown className="size-3.5" /> Neu
          </Tap>
        </div>
      )}

      <Dock
        screen={screen?.text}
        busy={busy}
        onType={(text, enter) => {
          stick.current = true
          onType(text, enter)
        }}
        onKey={(k) => {
          stick.current = true
          onKey(k)
        }}
      />
    </div>
  )
}

/**
 * Wrapped on a narrow screen, right-aligned bits (the prompt's clock, a
 * TUI's right column) would land on a line of their own after a run of
 * spaces — pull them in instead.
 */
function tidy(text: string) {
  return text.replace(/ {6,}(\S[^\n]{0,24})$/gm, '  $1')
}

function Pill({ on, onPress, label, children }: { on: boolean; onPress: () => void; label: string; children: React.ReactNode }) {
  return (
    <Tap
      onPress={onPress}
      label={label}
      className={cn(
        'size-8 rounded-full backdrop-blur-md',
        on ? 'bg-t1/85 text-bg' : 'bg-raised/80 text-t3 shadow-[0_1px_2px_rgb(0_0_0/0.12)]',
      )}
    >
      {children}
    </Tap>
  )
}
