import { ArrowUp, ChevronRight, FileText, PencilLine, Search, SquareTerminal, Wrench } from 'lucide-react'
import { Fragment, useEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import type { ChatItem, Key, Screen, Tab } from '@/lib/protocol'
import { TerminalView } from './TerminalView'

/**
 * Claude as a conversation, read from its transcript. Permission prompts
 * become buttons; the real terminal is one tap away for everything else.
 */
export function ClaudeView({
  tab,
  items,
  screen,
  history,
  onHistory,
  onType,
  onKey,
}: {
  tab: Tab
  items?: ChatItem[]
  screen?: Screen
  history: boolean
  onHistory: (on: boolean) => void
  onType: (text: string, enter: boolean) => void
  onKey: (key: Key) => void
}) {
  const [mode, setMode] = useState<'chat' | 'terminal'>(items === undefined ? 'terminal' : 'chat')
  const [draft, setDraft] = useState('')
  const end = useRef<HTMLDivElement>(null)

  // The transcript arrives a moment after the screen — switch once it does.
  const hadItems = useRef(items !== undefined)
  useEffect(() => {
    if (!hadItems.current && items !== undefined) {
      hadItems.current = true
      setMode('chat')
    }
  }, [items])

  useEffect(() => {
    end.current?.scrollIntoView({ block: 'end' })
  }, [items?.length, tab.agent, mode])

  const pending = tab.agent === 'blocked' ? [...(items ?? [])].reverse().find((i) => i.kind === 'tool' && !i.done) : undefined

  function send(text: string) {
    if (!text.trim()) return
    onType(text.trim(), true)
    setDraft('')
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex justify-center bg-bg pt-2">
        <Segmented
          value={mode}
          onChange={setMode}
          options={[
            ['chat', 'Chat'],
            ['terminal', 'Terminal'],
          ]}
        />
      </div>

      {mode === 'terminal' ? (
        <TerminalView
          screen={screen}
          history={history}
          onHistory={onHistory}
          onType={onType}
          onKey={onKey}
          extraKeys={['1', '2', '3', 'enter']}
        />
      ) : (
        <>
          <div className="flex-1 overflow-y-auto bg-bg px-4 pt-3 pb-4">
            {items === undefined || items.length === 0 ? (
              <p className="mt-10 px-6 text-center text-[14px] text-t4">
                {items === undefined
                  ? 'Der Verlauf erscheint, sobald Claude in dieser Session etwas tut. Bis dahin: Terminal.'
                  : 'Noch nichts in diesem Gespräch.'}
              </p>
            ) : (
              <div className="flex flex-col gap-3">
                {items.map((item, i) => (
                  <ChatRow key={i} item={item} />
                ))}
              </div>
            )}

            {tab.agent === 'working' && (
              <div className="mt-3 flex items-center gap-2 text-[14px] text-tone-blue">
                <span className="size-2 rounded-full bg-current pulse-soft" />
                Claude arbeitet …
                <button type="button" onClick={() => onKey('esc')} className="ml-auto rounded-lg border border-hair bg-raised px-2.5 py-1 text-[12.5px] font-medium text-t2">
                  Stopp
                </button>
              </div>
            )}

            {tab.agent === 'failed' && (
              <div className="mt-3 rounded-2xl border border-tone-red/25 bg-tone-red-soft p-3.5">
                <div className="text-[14px] font-semibold text-tone-red">Die Runde ist an einem API-Fehler gestorben</div>
                <p className="mt-0.5 text-[13.5px] text-t2">Details stehen im Terminal. „weiter“ schickt sie neu los.</p>
              </div>
            )}

            {tab.agent === 'blocked' && (
              <div className="mt-3 rounded-2xl border border-tone-orange/30 bg-tone-orange-soft p-3.5">
                <div className="text-[13px] font-semibold text-tone-orange">Claude braucht deine Freigabe</div>
                {pending?.kind === 'tool' && (
                  <code className="mt-1.5 block rounded-lg bg-raised px-2.5 py-2 font-mono text-[13px] break-all text-t1">
                    {pending.tool}: {pending.target}
                  </code>
                )}
                <div className="mt-3 grid grid-cols-2 gap-2">
                  <button type="button" onClick={() => onKey('1')} className="h-10 rounded-xl bg-t1 text-[14px] font-semibold text-bg active:opacity-80">
                    Erlauben
                  </button>
                  <button type="button" onClick={() => onKey('esc')} className="h-10 rounded-xl border border-hair bg-raised text-[14px] font-medium text-t1 active:bg-active">
                    Ablehnen
                  </button>
                  <button type="button" onClick={() => onKey('2')} className="col-span-2 h-9 rounded-xl text-[13px] font-medium text-t2 active:bg-active">
                    Immer erlauben (Option 2)
                  </button>
                </div>
                <button type="button" onClick={() => setMode('terminal')} className="mt-1 w-full text-center text-[12px] text-t3 underline-offset-2 active:underline">
                  Frage im Terminal ansehen
                </button>
              </div>
            )}
            <div ref={end} />
          </div>

          <div className="border-t border-hair bg-surface px-3 pt-2 pb-[calc(env(safe-area-inset-bottom,0px)+8px)]">
            {tab.agent === 'failed' && (
              <div className="mb-2 flex gap-1.5">
                <button type="button" onClick={() => send('weiter')} className="rounded-full border border-hair bg-raised px-3 py-1.5 text-[13px] text-t2 active:bg-active">
                  weiter
                </button>
              </div>
            )}
            <form
              className="flex items-end gap-2"
              onSubmit={(e) => {
                e.preventDefault()
                send(draft)
              }}
            >
              <div className="flex min-h-11 flex-1 items-end rounded-[22px] border border-hair bg-raised px-3.5 py-2.5">
                <textarea
                  id="claude-draft"
                  value={draft}
                  rows={1}
                  onChange={(e) => setDraft(e.target.value)}
                  placeholder={tab.agent === 'working' ? 'Nachricht für danach …' : 'Antwort an Claude …'}
                  className="max-h-32 flex-1 resize-none bg-transparent text-[16px] leading-[1.35] text-t1 outline-none placeholder:text-[15px] placeholder:text-t4"
                />
              </div>
              <button
                type="submit"
                aria-label="Senden"
                disabled={!draft.trim()}
                className="grid size-11 shrink-0 place-items-center rounded-full bg-claude text-white disabled:opacity-30"
              >
                <ArrowUp className="size-5" strokeWidth={2.6} />
              </button>
            </form>
          </div>
        </>
      )}
    </div>
  )
}

function ChatRow({ item }: { item: ChatItem }) {
  switch (item.kind) {
    case 'user':
      return (
        <div className="ml-10 self-end rounded-[20px] rounded-br-md bg-active px-3.5 py-2.5 text-[15px] leading-snug break-words whitespace-pre-wrap text-t1">
          {item.text}
        </div>
      )
    case 'claude':
      return <Rich text={item.text} />
    case 'tool':
      return <ToolRow item={item} />
  }
}

/** Just enough markdown for Claude's answers: code blocks, `code`, **bold**, headings. */
function Rich({ text }: { text: string }) {
  const blocks = text.split(/```[^\n]*\n?/)
  return (
    <div className="flex flex-col gap-2 pr-2 text-[15px] leading-relaxed text-t1">
      {blocks.map((block, i) =>
        i % 2 === 1 ? (
          <pre key={i} className="overflow-x-auto rounded-lg border border-hair bg-raised px-3 py-2 font-mono text-[12.5px] leading-[1.45] text-t2">
            {block.replace(/\n$/, '')}
          </pre>
        ) : (
          block
            .split(/\n{2,}/)
            .filter((p) => p.trim())
            .map((p, j) => {
              const heading = p.match(/^#{1,4}\s+(.*)/)
              return (
                <p key={`${i}-${j}`} className={cn('break-words whitespace-pre-wrap', heading && 'font-semibold')}>
                  <Inline text={heading ? heading[1] : p} />
                </p>
              )
            })
        ),
      )}
    </div>
  )
}

function Inline({ text }: { text: string }) {
  const parts = text.split(/(`[^`]+`|\*\*[^*]+\*\*)/)
  return (
    <>
      {parts.map((part, i) =>
        part.startsWith('`') && part.endsWith('`') ? (
          <code key={i} className="rounded bg-active px-1 font-mono text-[0.88em]">
            {part.slice(1, -1)}
          </code>
        ) : part.startsWith('**') && part.endsWith('**') ? (
          <strong key={i} className="font-semibold">
            {part.slice(2, -2)}
          </strong>
        ) : (
          <Fragment key={i}>{part}</Fragment>
        ),
      )}
    </>
  )
}

function ToolRow({ item }: { item: Extract<ChatItem, { kind: 'tool' }> }) {
  const [open, setOpen] = useState(false)
  const Icon =
    item.tool === 'Bash'
      ? SquareTerminal
      : item.tool === 'Edit' || item.tool === 'Write'
        ? PencilLine
        : item.tool === 'Grep' || item.tool === 'Glob'
          ? Search
          : item.tool === 'Read'
            ? FileText
            : Wrench
  const summary = item.output?.filter((l) => l.trim()).at(-1)
  return (
    <div className={cn('rounded-xl border bg-raised', item.error ? 'border-tone-red/35' : 'border-hair')}>
      <button type="button" onClick={() => setOpen(!open)} aria-expanded={open} className="flex w-full items-center gap-2 px-3 py-2 text-left">
        <Icon className="size-4 shrink-0 text-t3" />
        <span className="shrink-0 text-[13px] font-medium text-t2">{item.tool}</span>
        <span className="min-w-0 flex-1 truncate font-mono text-[12.5px] text-t3">{item.target}</span>
        {!item.done && <span className="size-1.5 shrink-0 rounded-full bg-tone-blue pulse-soft" />}
        <ChevronRight className={cn('size-4 shrink-0 text-t4 transition-transform', open && 'rotate-90')} />
      </button>
      {!open && summary && item.tool !== 'Read' && (
        <div className={cn('truncate px-3 pb-2 font-mono text-[12px]', item.error ? 'text-tone-red' : 'text-t4')}>{summary}</div>
      )}
      {open && (
        <div className="overflow-x-auto border-t border-hair px-3 py-2 font-mono text-[12px] leading-[1.5]">
          {item.diff?.map((d, i) => (
            <div
              key={`d${i}`}
              className={cn('whitespace-pre', d.sign === '+' && 'text-ansi-green', d.sign === '-' && 'text-ansi-red', d.sign === ' ' && 'text-t3')}
            >
              {d.sign} {d.text}
            </div>
          ))}
          {item.output?.map((l, i) => (
            <div key={`o${i}`} className={cn('whitespace-pre', item.error ? 'text-tone-red' : 'text-t2')}>
              {l || ' '}
            </div>
          ))}
          {!item.diff && !item.output && <div className="text-t4">Kein Ergebnis (noch).</div>}
        </div>
      )}
    </div>
  )
}

export function Segmented<T extends string>({ value, onChange, options }: { value: T; onChange: (v: T) => void; options: [T, string][] }) {
  return (
    <div className="inline-flex rounded-lg bg-active p-0.5" role="tablist">
      {options.map(([v, label]) => (
        <button
          key={v}
          type="button"
          role="tab"
          aria-selected={value === v}
          onClick={() => onChange(v)}
          className={cn('h-7 rounded-md px-3.5 text-[13px] font-medium transition-colors', value === v ? 'bg-raised text-t1 shadow-[0_1px_2px_rgb(0_0_0/0.08)]' : 'text-t3')}
        >
          {label}
        </button>
      ))}
    </div>
  )
}
