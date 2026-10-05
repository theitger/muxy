import { ChevronRight, FileText, PencilLine, Search, SquareTerminal, Wrench } from 'lucide-react'
import { Fragment, useEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import type { ChatItem, Key, Screen, Tab } from '@/lib/protocol'
import { TerminalView } from './TerminalView'
import { Dock } from '@/components/Dock'

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
  onKey: (key: Key | string) => void
}) {
  const [mode, setMode] = useState<'chat' | 'terminal'>(items === undefined ? 'terminal' : 'chat')
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
          busy={tab.agent === 'working'}
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


            {tab.agent === 'failed' && (
              <div className="mt-3 rounded-2xl border border-tone-red/25 bg-tone-red-soft p-3.5">
                <div className="text-[14px] font-semibold text-tone-red">Die Runde ist an einem API-Fehler gestorben</div>
                <p className="mt-0.5 text-[13.5px] text-t2">Details stehen im Terminal. „weiter“ schickt sie neu los.</p>
              </div>
            )}

            <div ref={end} />
          </div>

          <Dock
            screen={screen?.text}
            busy={tab.agent === 'working'}
            onType={onType}
            onKey={onKey}
            multiline
            keys={false}
            placeholder={tab.agent === 'working' ? 'Nachricht für danach …' : tab.agent === 'failed' ? '„weiter“ schickt die Runde neu los' : 'Antwort an Claude …'}
          />
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
  const summary = item.output?.filter((l) => l.trim() && !/^… \d+ more lines$/.test(l)).at(-1)
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
