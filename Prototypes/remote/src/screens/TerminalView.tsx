import { CornerDownLeft, History, WrapText } from 'lucide-react'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import { Key as KeyButton } from '@/components/muxy'
import type { Key, Screen } from '@/lib/protocol'

function stored(name: string, fallback: boolean) {
  try {
    const v = localStorage.getItem(name)
    return v === null ? fallback : v === '1'
  } catch {
    return fallback
  }
}
function store(name: string, value: boolean) {
  try {
    localStorage.setItem(name, value ? '1' : '0')
  } catch {
    /* not kept */
  }
}

/**
 * The tab's real screen as Muxy reads it from Ghostty (text only for now),
 * a line to type into and the keys a phone keyboard lacks.
 */
export function TerminalView({
  screen,
  history,
  onHistory,
  onType,
  onKey,
  extraKeys = [],
}: {
  screen?: Screen
  history: boolean
  onHistory: (on: boolean) => void
  onType: (text: string, enter: boolean) => void
  onKey: (key: Key) => void
  extraKeys?: Key[]
}) {
  const [draft, setDraft] = useState('')
  const [wrap, setWrap] = useState(() => stored('muxy.wrap', true))
  const scroller = useRef<HTMLDivElement>(null)
  const stick = useRef(true)

  // Follow the output unless you scrolled up to read.
  useLayoutEffect(() => {
    const el = scroller.current
    if (el && stick.current) el.scrollTop = el.scrollHeight
  }, [screen?.text, wrap])

  useEffect(() => {
    stick.current = true
  }, [history])

  const keys: [Key, string][] = [
    ['esc', 'esc'],
    ['tab', 'tab'],
    ['shift-tab', '⇧tab'],
    ['ctrl-c', '^C'],
    ['up', '↑'],
    ['down', '↓'],
    ['left', '←'],
    ['right', '→'],
    ...extraKeys.map((k) => [k, k] as [Key, string]),
    ['ctrl-r', '^R'],
    ['backspace', '⌫'],
  ]

  return (
    <div className="flex min-h-0 flex-1 flex-col bg-bg">
      <div className="flex items-center justify-end gap-1 px-2 pt-1.5">
        <Toggle on={history} onClick={() => onHistory(!history)} label="Verlauf">
          <History className="size-3.5" />
        </Toggle>
        <Toggle
          on={wrap}
          onClick={() => {
            setWrap(!wrap)
            store('muxy.wrap', !wrap)
          }}
          label="Umbrechen"
        >
          <WrapText className="size-3.5" />
        </Toggle>
      </div>

      <div
        ref={scroller}
        onScroll={(e) => {
          const el = e.currentTarget
          stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40
        }}
        className={cn('flex-1 overflow-auto px-4 pt-1 pb-3', !wrap && 'overflow-x-auto')}
      >
        {screen ? (
          <pre
            className={cn(
              'font-mono text-[12.5px] leading-[1.38] text-term',
              wrap ? 'break-words whitespace-pre-wrap' : 'w-max whitespace-pre',
            )}
          >
            {(wrap ? tidy(screen.text) : screen.text) || ' '}
          </pre>
        ) : (
          <p className="mt-10 text-center text-[14px] text-t4">Lädt den Bildschirm …</p>
        )}
      </div>

      <div className="border-t border-hair bg-surface pt-2 pb-[calc(env(safe-area-inset-bottom,0px)+8px)]">
        <div className="mb-2 flex gap-1.5 overflow-x-auto px-3">
          {keys.map(([k, label]) => (
            <KeyButton key={k} wide={label.length > 2} onPress={() => onKey(k)} label={k}>
              {label}
            </KeyButton>
          ))}
        </div>
        <form
          className="flex items-center gap-2 px-3"
          onSubmit={(e) => {
            e.preventDefault()
            onType(draft, true)
            setDraft('')
            stick.current = true
          }}
        >
          <div className="flex h-11 flex-1 items-center gap-2 rounded-xl border border-hair bg-raised px-3">
            <span className="font-mono text-[14px] font-bold text-ss-char">→</span>
            <input
              id="terminal-input"
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              autoCapitalize="off"
              autoCorrect="off"
              autoComplete="off"
              spellCheck={false}
              enterKeyHint="send"
              placeholder="Eingabe, ⏎ schickt sie ab"
              className="min-w-0 flex-1 bg-transparent font-mono text-[16px] text-t1 outline-none placeholder:text-[14px] placeholder:text-t4"
            />
          </div>
          <button
            type="submit"
            aria-label="Senden mit Enter"
            className="grid size-11 shrink-0 place-items-center rounded-xl bg-t1 text-bg active:opacity-80"
          >
            <CornerDownLeft className="size-5" />
          </button>
        </form>
      </div>
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

function Toggle({ on, onClick, label, children }: { on: boolean; onClick: () => void; label: string; children: React.ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={on}
      className={cn(
        'flex h-7 items-center gap-1 rounded-lg px-2 text-[12px] font-medium',
        on ? 'bg-active text-t1' : 'text-t4',
      )}
    >
      {children}
      {label}
    </button>
  )
}
