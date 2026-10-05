import { ArrowUp, CornerDownLeft, OctagonX } from 'lucide-react'
import { useMemo, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import { keysFor, readHint } from '@/lib/hints'
import type { Key } from '@/lib/protocol'
import { KeyCap, Tap, Trackpad } from './touch'

/**
 * Everything you do to a terminal from the phone, sitting on top of the
 * keyboard like a native input bar:
 *
 * - what the screen asks for, as answers (a pick list's real options,
 *   y/n) — tap what you mean, not the keys that select it,
 * - the line you type, sent with return; return or ⌫ on an empty line go
 *   straight to the terminal,
 * - the keys a phone lacks: esc, tab, a sticky ctrl, and a trackpad for
 *   the arrows.
 */
export function Dock({
  screen,
  busy,
  onType,
  onKey,
  placeholder = 'Eingabe',
  multiline = false,
  keys = true,
}: {
  screen?: string
  busy?: boolean
  onType: (text: string, enter: boolean) => void
  onKey: (key: Key | string) => void
  placeholder?: string
  multiline?: boolean
  keys?: boolean
}) {
  const [draft, setDraft] = useState('')
  const [ctrl, setCtrl] = useState(false)
  const field = useRef<HTMLTextAreaElement & HTMLInputElement>(null)
  const typing = useRef(false)
  const hint = useMemo(() => readHint(screen), [screen])

  // A key tapped while typing must not close the keyboard.
  const keepTyping = () => {
    if (typing.current) field.current?.focus()
  }
  const press = (key: Key | string) => {
    onKey(key)
    keepTyping()
  }
  const send = (keys: string[]) => keys.forEach((k, i) => setTimeout(() => onKey(k), i * 40))

  function submit() {
    if (draft) onType(draft, true)
    else onKey('enter')
    setDraft('')
    keepTyping()
  }

  return (
    <div
      className="border-t border-hair bg-surface/95 pb-[calc(env(safe-area-inset-bottom,0px)+6px)] backdrop-blur-xl"
      onPointerDownCapture={() => {
        typing.current = document.activeElement === field.current
      }}
    >
      {hint?.kind === 'menu' && (
        <div className="px-3 pt-3">
          {hint.question && <div className="mb-2 px-1 text-[13px] font-medium text-t3">{hint.question}</div>}
          <div className="flex flex-col overflow-hidden rounded-2xl bg-raised shadow-[0_1px_0_rgb(0_0_0/0.06)]">
            {hint.choices.map((c, i) => (
              <Tap
                key={i}
                onPress={() => send(keysFor(hint.choices, i))}
                className={cn(
                  'min-h-12 justify-start gap-3 px-4 py-2.5 text-left text-[15.5px]',
                  i > 0 && 'border-t border-hair',
                  c.selected ? 'font-semibold text-t1' : 'text-t2',
                )}
              >
                <span className={cn('size-2 shrink-0 rounded-full', c.selected ? 'bg-claude' : 'bg-transparent')} />
                <span className="leading-snug">{c.label}</span>
              </Tap>
            ))}
          </div>
        </div>
      )}

      {hint?.kind === 'yesno' && (
        <div className="grid grid-cols-2 gap-2 px-3 pt-3">
          <Tap onPress={() => press('y')} className="h-12 rounded-2xl bg-t1 text-[16px] font-semibold text-bg">
            Ja
          </Tap>
          <Tap onPress={() => press('n')} className="h-12 rounded-2xl bg-raised text-[16px] font-semibold text-t1">
            Nein
          </Tap>
        </div>
      )}

      {busy && !hint && (
        <div className="flex justify-center px-3 pt-2.5">
          <Tap
            onPress={() => press('esc')}
            className="h-9 gap-1.5 rounded-full bg-tone-red-soft px-4 text-[14px] font-semibold text-tone-red"
          >
            <OctagonX className="size-4" /> Stopp
          </Tap>
        </div>
      )}

      {keys && (
        <div className="flex items-center gap-1.5 overflow-x-auto px-3 pt-2.5 [scrollbar-width:none]">
          <KeyCap label="Escape" wide onPress={() => press('esc')}>
            esc
          </KeyCap>
          <KeyCap label="Tab" wide onPress={() => press('tab')}>
            ⇥
          </KeyCap>
          <KeyCap
            label="Control, gilt für das nächste Zeichen"
            wide
            active={ctrl}
            onPress={() => {
              setCtrl(!ctrl)
              keepTyping()
            }}
          >
            ctrl
          </KeyCap>
          <Trackpad onArrow={(a) => onKey(a)} />
          <KeyCap label="Shift-Tab" onPress={() => press('shift-tab')}>
            ⇤
          </KeyCap>
          <KeyCap label="Control-C" onPress={() => press('ctrl-c')}>
            ^C
          </KeyCap>
        </div>
      )}

      <form
        className="flex items-end gap-2 px-3 pt-2.5"
        onSubmit={(e) => {
          e.preventDefault()
          submit()
        }}
      >
        <div
          className={cn(
            'flex min-h-11 flex-1 items-center rounded-[22px] border bg-raised px-4 py-2',
            ctrl ? 'border-t1' : 'border-hair',
          )}
        >
          {ctrl && <span className="mr-2 rounded bg-t1 px-1.5 py-0.5 font-mono text-[12px] text-bg">ctrl</span>}
          {multiline ? (
            <textarea
              ref={field}
              id="dock-input"
              value={draft}
              rows={1}
              onChange={(e) => setDraft(e.target.value)}
              placeholder={placeholder}
              className="max-h-32 flex-1 resize-none bg-transparent text-[16px] leading-[1.35] text-t1 outline-none placeholder:text-t4"
            />
          ) : (
            <input
              ref={field}
              id="dock-input"
              value={draft}
              onChange={(e) => {
                const value = e.target.value
                // ctrl + a letter: that control key, not text.
                if (ctrl && value.length === draft.length + 1) {
                  const letter = value.slice(-1).toLowerCase()
                  if (/[a-z]/.test(letter)) {
                    onKey(`ctrl-${letter}`)
                    setCtrl(false)
                    return
                  }
                }
                setDraft(value)
              }}
              onKeyDown={(e) => {
                // ⌫ on an empty line deletes in the terminal.
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
        <Tap
          label={draft ? 'Senden' : 'Return'}
          onPress={submit}
          className={cn(
            'size-11 shrink-0 rounded-full',
            draft ? 'bg-claude text-white' : 'bg-keycap text-t2 shadow-[0_1px_0_rgb(0_0_0/0.28)]',
          )}
        >
          {draft ? <ArrowUp className="size-5" strokeWidth={2.6} /> : <CornerDownLeft className="size-[18px]" />}
        </Tap>
      </form>
    </div>
  )
}
