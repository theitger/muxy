import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, Square } from 'lucide-react'
import { useLayoutEffect, useMemo, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import { keysFor, readHint } from '@/lib/hints'
import { t } from '@/lib/i18n'
import type { InputDelivery, Key } from '@/lib/protocol'
import { Tap } from './touch'

/**
 * The input bar, built like a messaging app's: one field that grows with
 * what you write, and send. In a terminal a key row rides on top, like the
 * accessory bar of terminal apps; a question on screen shows up as answers.
 */
export function Composer({
  screen,
  busy,
  history = [],
  onType,
  onKey,
  placeholder,
  terminal = false,
}: {
  /** The screen's text, read for a question to offer as answers. */
  screen?: string
  busy?: boolean
  history?: string[]
  onType: (text: string, enter: boolean) => boolean | void | InputDelivery | Promise<boolean | InputDelivery>
  onKey: (key: Key | string) => boolean | void | InputDelivery | Promise<boolean | InputDelivery>
  placeholder: string
  /** Typed into a terminal: a command line, keys, suggestions. */
  terminal?: boolean
}) {
  const [draft, setDraft] = useState('')
  const submitting = useRef(false)
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [sendFailed, setSendFailed] = useState(false)
  const [partiallySent, setPartiallySent] = useState(false)
  const [focused, setFocused] = useState(false)
  const [ctrl, setCtrl] = useState(false)
  const field = useRef<HTMLTextAreaElement>(null)
  const hint = useMemo(() => (screen === undefined ? null : readHint(screen)), [screen])

  const suggestions = useMemo(() => {
    if (!terminal) return []
    const q = draft.trim().toLowerCase()
    return history.filter((c) => c.toLowerCase() !== q && (!q || c.toLowerCase().includes(q))).slice(0, 12)
  }, [history, draft, terminal])

  // Grows with the text, up to a few lines, like Messages.
  useLayoutEffect(() => {
    const el = field.current
    if (!el) return
    el.style.height = '0px'
    el.style.height = `${Math.min(el.scrollHeight, 148)}px`
  }, [draft])

  const sendKeys = (list: string[]) => list.forEach((k, i) => setTimeout(() => onKey(k), i * 40))

  async function submit() {
    if (submitting.current) return
    const text = draft
    if (!text.trim() && !terminal && !partiallySent) return
    submitting.current = true
    setIsSubmitting(true)
    setSendFailed(false)
    try {
      const accepted = text.trim() ? await onType(terminal ? text : text.trim(), true) : await onKey('enter')
      const failed = accepted === false || accepted === 'rejected' || accepted === 'unconfirmed'
      setSendFailed(failed)
      setPartiallySent(accepted === 'partial')
      if (!failed) setDraft((current) => current === text ? '' : current)
    } catch {
      setSendFailed(true)
    } finally {
      submitting.current = false
      setIsSubmitting(false)
    }
  }

  return (
    <div className="relative z-10 shrink-0 border-t border-hair bg-surface/85 pb-[calc(env(safe-area-inset-bottom,0px)+6px)] backdrop-blur-xl backdrop-saturate-150 [.keyboard-open_&]:pb-1.5">
      {partiallySent && <p role="alert" className="px-4 pt-2 text-[13px] text-t2">{t('Text reached the terminal, but Enter was not confirmed. Check the terminal and press Return to submit.')}</p>}
      {sendFailed && <p role="alert" className="px-4 pt-2 text-[13px] text-t2">{t('Input not confirmed. Check the terminal before trying again; your text is still here.')}</p>}
      {hint?.kind === 'menu' && (
        <div className="fade-in px-3 pt-2.5">
          {hint.question && <div className="mb-1.5 px-1 text-[13px] text-t3">{hint.question}</div>}
          <div className="overflow-hidden rounded-[12px] bg-raised">
            {hint.choices.map((c, i) => (
              <Tap
                key={i}
                onPress={() => sendKeys(keysFor(hint.choices, i))}
                className={cn('row-press min-h-[44px] w-full justify-start px-3.5 py-2 text-left text-[16px] text-t1', i > 0 && 'border-t border-hair', c.selected && 'font-semibold text-brand')}
              >
                <span className="leading-snug">{c.label}</span>
              </Tap>
            ))}
          </div>
        </div>
      )}

      {hint?.kind === 'yesno' && (
        <div className="fade-in grid grid-cols-2 gap-2 px-3 pt-2.5">
          <Tap onPress={() => onKey('y')} className="h-11 rounded-[12px] bg-raised text-[16px] font-semibold text-brand">
            {t('Yes')}
          </Tap>
          <Tap onPress={() => onKey('n')} className="h-11 rounded-[12px] bg-raised text-[16px] text-t1">
            {t('No')}
          </Tap>
        </div>
      )}

      {terminal && focused && suggestions.length > 0 && (
        <div className="no-scrollbar flex gap-1.5 overflow-x-auto px-3 pt-2">
          {suggestions.map((c) => (
            <Tap key={c} onPress={() => setDraft(c)} className="h-8 max-w-[70vw] shrink-0 rounded-full bg-raised px-3 font-mono text-[13px] text-t2">
              <span className="truncate">{c}</span>
            </Tap>
          ))}
        </div>
      )}

      {terminal && (
        <div className="no-scrollbar flex gap-1.5 overflow-x-auto px-3 pt-2">
          <KeyChip onPress={() => onKey('esc')}>esc</KeyChip>
          <KeyChip onPress={() => setCtrl(!ctrl)} active={ctrl} label="Control">
            ctrl
          </KeyChip>
          <KeyChip onPress={() => onKey('tab')} label="Tab">
            tab
          </KeyChip>
          <KeyChip onPress={() => onKey('ctrl-c')} label="Control C">
            ^C
          </KeyChip>
          <KeyChip onPress={() => onKey('up')} label={t('Up')}>
            <ArrowUp className="size-4" />
          </KeyChip>
          <KeyChip onPress={() => onKey('down')} label={t('Down')}>
            <ArrowDown className="size-4" />
          </KeyChip>
          <KeyChip onPress={() => onKey('left')} label={t('Left')}>
            <ArrowLeft className="size-4" />
          </KeyChip>
          <KeyChip onPress={() => onKey('right')} label={t('Right')}>
            <ArrowRight className="size-4" />
          </KeyChip>
          <KeyChip onPress={() => onKey('shift-tab')} label="Shift Tab">
            ⇧tab
          </KeyChip>
          <KeyChip onPress={() => onKey('ctrl-r')} label="Control R">
            ^R
          </KeyChip>
          <KeyChip onPress={() => onKey('ctrl-d')} label="Control D">
            ^D
          </KeyChip>
        </div>
      )}

      <form
        className="flex items-end gap-2 px-3 pt-2"
        onSubmit={(e) => {
          e.preventDefault()
          submit()
        }}
      >
        <div className={cn('flex min-h-[38px] flex-1 items-center rounded-[19px] border bg-raised px-3.5 transition-colors', ctrl ? 'border-brand' : 'border-hair')}>
          <textarea
            ref={field}
            value={draft}
            rows={1}
            onChange={(e) => {
              const value = e.target.value
              // ⌃ armed: the next letter goes as a control key.
              if (ctrl && value.length > draft.length) {
                const letter = value.slice(-1).toLowerCase()
                if (/[a-z]/.test(letter)) onKey(`ctrl-${letter}`)
                setCtrl(false)
                return
              }
              setDraft(value)
            }}
            onFocus={() => setFocused(true)}
            onBlur={() => setFocused(false)}
            onKeyDown={(e) => {
              if (terminal && e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
                e.preventDefault()
                submit()
              }
              // ⌫ on an empty line deletes in the terminal.
              if (terminal && e.key === 'Backspace' && draft === '') {
                e.preventDefault()
                onKey('backspace')
              }
            }}
            autoCapitalize={terminal ? 'off' : 'sentences'}
            autoCorrect={terminal ? 'off' : 'on'}
            autoComplete="off"
            spellCheck={!terminal}
            enterKeyHint={terminal ? 'send' : 'enter'}
            placeholder={ctrl ? t('Letter for ctrl') : placeholder}
            className={cn(
              'block max-h-[148px] w-full resize-none bg-transparent py-[8px] text-[16px] leading-[22px] text-t1 outline-none placeholder:text-t4',
              terminal && 'font-mono placeholder:font-sans',
            )}
          />
        </div>
        {busy && !draft && (
          <Tap label={t('Stop')} onPress={() => onKey('esc')} className="size-[38px] shrink-0 rounded-full bg-t1 text-bg">
            <Square className="size-[13px]" fill="currentColor" strokeWidth={0} />
          </Tap>
        )}
        <Tap
          label={isSubmitting ? t('Sending …') : draft ? t('Send') : 'Return'}
          onPress={submit}
          disabled={isSubmitting || (!terminal && !partiallySent && !draft.trim())}
          className={cn('size-[38px] shrink-0 rounded-full transition-colors duration-150', draft.trim() ? 'bg-brand text-bg' : 'bg-active text-t3')}
        >
          <ArrowUp className="size-[20px]" strokeWidth={2.6} />
        </Tap>
      </form>
    </div>
  )
}

function KeyChip({ children, onPress, active, label }: { children: React.ReactNode; onPress: () => void; active?: boolean; label?: string }) {
  return (
    <Tap
      onPress={onPress}
      label={label}
      className={cn('h-[34px] min-w-[44px] shrink-0 rounded-[8px] px-2.5 font-mono text-[14px] shadow-[0_1px_0_rgb(0_0_0/0.18)]', active ? 'bg-brand text-bg' : 'bg-keycap text-t1')}
    >
      {children}
    </Tap>
  )
}
