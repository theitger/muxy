import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, ChevronUp, CornerDownLeft, Square } from 'lucide-react'
import { useMemo, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import { keysFor, readHint } from '@/lib/hints'
import type { Key } from '@/lib/protocol'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Tap } from './touch'

/**
 * The input bar, built like a messaging app's: one field, send, and ⌃ for
 * the keys a phone lacks. Above it only what helps right now:
 *
 * - the screen's question as answers (a pick list's real options, y/n),
 * - while typing, your recent commands like keyboard suggestions — tap one
 *   to edit it, the newest is the last command,
 * - a stop button while Claude works.
 *
 * Return or ⌫ on an empty field go straight to the terminal.
 */
export function Dock({
  screen,
  busy,
  history = [],
  onType,
  onKey,
  placeholder = 'Befehl',
  multiline = false,
}: {
  screen?: string
  busy?: boolean
  history?: string[]
  onType: (text: string, enter: boolean) => void
  onKey: (key: Key | string) => void
  placeholder?: string
  multiline?: boolean
}) {
  const [draft, setDraft] = useState('')
  const [focused, setFocused] = useState(false)
  const [keys, setKeys] = useState(false)
  const field = useRef<HTMLTextAreaElement & HTMLInputElement>(null)
  const hint = useMemo(() => readHint(screen), [screen])

  const suggestions = useMemo(() => {
    if (multiline) return []
    const q = draft.trim().toLowerCase()
    return history.filter((c) => c.toLowerCase() !== q && (!q || c.toLowerCase().includes(q))).slice(0, 12)
  }, [history, draft, multiline])

  const sendKeys = (list: string[]) => list.forEach((k, i) => setTimeout(() => onKey(k), i * 40))

  function submit() {
    if (draft) onType(draft, true)
    else onKey('enter')
    setDraft('')
  }

  return (
    <div className="border-t border-hair bg-surface/95 pb-[calc(env(safe-area-inset-bottom,0px)+8px)] backdrop-blur-xl">
      {hint?.kind === 'menu' && (
        <div className="px-3 pt-3">
          {hint.question && <div className="mb-1.5 px-1 text-[13px] text-t3">{hint.question}</div>}
          <div className="overflow-hidden rounded-[14px] bg-raised">
            {hint.choices.map((c, i) => (
              <Tap
                key={i}
                onPress={() => sendKeys(keysFor(hint.choices, i))}
                className={cn(
                  'flex min-h-[46px] w-full justify-between gap-3 px-4 py-2.5 text-left text-[16px] text-t1 active:bg-active',
                  i > 0 && 'border-t border-hair',
                )}
              >
                <span className="leading-snug">{c.label}</span>
                {c.selected && <span className="text-[13px] text-t4">⏎</span>}
              </Tap>
            ))}
          </div>
        </div>
      )}

      {hint?.kind === 'yesno' && (
        <div className="grid grid-cols-2 gap-2 px-3 pt-3">
          <Tap onPress={() => onKey('y')} className="h-11 rounded-[14px] bg-raised text-[16px] font-semibold text-t1 active:bg-active">
            Ja
          </Tap>
          <Tap onPress={() => onKey('n')} className="h-11 rounded-[14px] bg-raised text-[16px] font-semibold text-t1 active:bg-active">
            Nein
          </Tap>
        </div>
      )}

      {focused && suggestions.length > 0 && (
        <div className="flex gap-1.5 overflow-x-auto px-3 pt-2.5 [scrollbar-width:none]">
          {suggestions.map((c) => (
            <Tap
              key={c}
              onPress={() => setDraft(c)}
              className="h-8 max-w-[70vw] shrink-0 rounded-full bg-raised px-3 font-mono text-[13px] text-t2 active:bg-active"
            >
              <span className="truncate">{c}</span>
            </Tap>
          ))}
        </div>
      )}

      <form
        className="flex items-end gap-2 px-3 pt-2.5"
        onSubmit={(e) => {
          e.preventDefault()
          submit()
        }}
      >
        <Tap
          label="Tasten"
          onPress={() => {
            field.current?.blur()
            setKeys(true)
          }}
          className="size-11 shrink-0 rounded-full bg-raised text-t2 active:bg-active"
        >
          <ChevronUp className="size-5" strokeWidth={2.4} />
        </Tap>
        <div className="flex min-h-11 flex-1 items-center rounded-[22px] bg-raised px-4 py-2">
          {multiline ? (
            <textarea
              ref={field}
              id="dock-input"
              value={draft}
              rows={1}
              onChange={(e) => setDraft(e.target.value)}
              onFocus={() => setFocused(true)}
              onBlur={() => setFocused(false)}
              placeholder={placeholder}
              className="max-h-32 flex-1 resize-none bg-transparent text-[16px] leading-[1.35] text-t1 outline-none placeholder:text-t4"
            />
          ) : (
            <input
              ref={field}
              id="dock-input"
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onFocus={() => setFocused(true)}
              onBlur={() => setFocused(false)}
              onKeyDown={(e) => {
                // ⌫ on an empty field deletes in the terminal.
                if (e.key === 'Backspace' && draft === '') {
                  e.preventDefault()
                  onKey('backspace')
                }
              }}
              autoCapitalize="off"
              autoCorrect="off"
              autoComplete="off"
              spellCheck={false}
              enterKeyHint="send"
              placeholder={placeholder}
              className="min-w-0 flex-1 bg-transparent font-mono text-[16px] text-t1 outline-none placeholder:font-sans placeholder:text-t4"
            />
          )}
        </div>
        {busy && !draft ? (
          <Tap label="Stopp" onPress={() => onKey('esc')} className="size-11 shrink-0 rounded-full bg-t1 text-bg">
            <Square className="size-4" fill="currentColor" />
          </Tap>
        ) : (
          <Tap
            label={draft ? 'Senden' : 'Return'}
            onPress={submit}
            className={cn('size-11 shrink-0 rounded-full', draft ? 'bg-claude text-white' : 'bg-raised text-t2 active:bg-active')}
          >
            {draft ? <ArrowUp className="size-5" strokeWidth={2.6} /> : <CornerDownLeft className="size-[18px]" />}
          </Tap>
        )}
      </form>

      <KeySheet open={keys} onOpenChange={setKeys} onKey={onKey} />
    </div>
  )
}

/** The keys a phone lacks, big, one sheet away. Stays open while you press. */
function KeySheet({ open, onOpenChange, onKey }: { open: boolean; onOpenChange: (open: boolean) => void; onKey: (key: string) => void }) {
  const key = (k: string, label: React.ReactNode, hint?: string) => (
    <Tap
      key={k}
      label={hint ?? k}
      onPress={() => onKey(k)}
      className="h-14 flex-col gap-0.5 rounded-[14px] bg-raised text-[17px] font-medium text-t1 active:bg-active"
    >
      {label}
      {hint && <span className="text-[10.5px] font-normal text-t4">{hint}</span>}
    </Tap>
  )
  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="bottom" className="rounded-t-[22px] border-hair bg-surface px-4 pt-2 pb-[calc(env(safe-area-inset-bottom,0px)+16px)]">
        <SheetHeader className="px-0">
          <SheetTitle>Tasten</SheetTitle>
          <SheetDescription className="sr-only">Sondertasten für das Terminal</SheetDescription>
        </SheetHeader>
        <div className="grid grid-cols-4 gap-2">
          {key('esc', 'esc')}
          {key('tab', '⇥', 'Tab')}
          {key('shift-tab', '⇤', 'Shift-Tab')}
          {key('enter', '⏎', 'Return')}
          {key('ctrl-c', '⌃C', 'Abbrechen')}
          {key('ctrl-d', '⌃D', 'Ende')}
          {key('ctrl-r', '⌃R', 'Suche')}
          {key('ctrl-l', '⌃L', 'Leeren')}
        </div>
        <div className="mx-auto mt-4 grid w-[204px] grid-cols-3 gap-2">
          <span />
          {key('up', <ArrowUp className="size-5" />, 'hoch')}
          <span />
          {key('left', <ArrowLeft className="size-5" />)}
          {key('down', <ArrowDown className="size-5" />, 'runter')}
          {key('right', <ArrowRight className="size-5" />)}
        </div>
      </SheetContent>
    </Sheet>
  )
}
