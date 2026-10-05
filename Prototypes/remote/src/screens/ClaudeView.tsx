import { ArrowUp, ChevronRight, FileText, Mic, Search, SquareTerminal, PencilLine } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import { Key } from '@/components/muxy'
import type { Agent, ChatItem, Tab } from '@/data'
import { ClaudeTui } from './ClaudeTui'

type ClaudeTab = Extract<Tab, { kind: 'claude' }>

/**
 * Claude as a conversation, built from the transcript the hook points at.
 * Permission prompts are buttons; the raw TUI is one tap away.
 */
export function ClaudeView({
  tab,
  agent,
  branch,
  onPermission,
  onSend,
}: {
  tab: ClaudeTab
  agent: Agent
  branch: string
  onPermission: (choice: 'yes' | 'always' | 'no') => void
  onSend: (text: string) => void
}) {
  const [mode, setMode] = useState<'chat' | 'terminal'>('chat')
  const [draft, setDraft] = useState('')
  const end = useRef<HTMLDivElement>(null)

  useEffect(() => {
    end.current?.scrollIntoView({ block: 'end' })
  }, [tab.chat.length, mode])

  const quick =
    agent === 'failed'
      ? ['weiter']
      : agent === 'idle'
        ? ['Ja, rebase', 'Zeig den Diff', '/compact']
        : ['/compact', 'Kurz zusammenfassen']

  function send(text: string) {
    if (!text.trim()) return
    onSend(text.trim())
    setDraft('')
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex justify-center pt-2">
        <Segmented
          value={mode}
          onChange={setMode}
          options={[
            ['chat', 'Chat'],
            ['terminal', 'Terminal'],
          ]}
        />
      </div>

      {mode === 'chat' ? (
        <div className="flex-1 overflow-y-auto px-4 pt-3 pb-4">
          <div className="flex flex-col gap-3">
            {tab.chat.map((item, i) => (
              <ChatRow key={i} item={item} onPermission={onPermission} />
            ))}
          </div>
          <div ref={end} />
        </div>
      ) : (
        <div className="flex-1 overflow-y-auto bg-bg px-4 py-3">
          <ClaudeTui chat={tab.chat} branch={branch} working={agent === 'working'} />
          <div ref={end} />
        </div>
      )}

      {mode === 'terminal' ? (
        <div className="flex gap-1.5 overflow-x-auto border-t border-hair bg-surface px-3 py-2 pb-[calc(env(safe-area-inset-bottom,0px)+8px)]">
          {['1', '2', '3'].map((k) => (
            <Key key={k} onPress={() => onPermission(k === '1' ? 'yes' : k === '2' ? 'always' : 'no')}>
              {k}
            </Key>
          ))}
          <Key wide onPress={() => onPermission('no')}>esc</Key>
          <Key wide onPress={() => {}}>⇧tab</Key>
          <Key onPress={() => {}}>↑</Key>
          <Key onPress={() => {}}>↓</Key>
          <Key onPress={() => onPermission('yes')}>⏎</Key>
        </div>
      ) : (
        <div className="border-t border-hair bg-surface px-3 pt-2 pb-[calc(env(safe-area-inset-bottom,0px)+8px)]">
          <div className="mb-2 flex gap-1.5 overflow-x-auto">
            {quick.map((q) => (
              <button
                key={q}
                type="button"
                onClick={() => send(q)}
                className="shrink-0 rounded-full border border-hair bg-raised px-3 py-1.5 text-[13px] text-t2 active:bg-active"
              >
                {q}
              </button>
            ))}
          </div>
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
                placeholder={agent === 'working' ? 'Nachricht für danach …' : 'Antwort an Claude …'}
                className="max-h-32 flex-1 resize-none bg-transparent text-[15px] leading-[1.35] text-t1 outline-none placeholder:text-t4"
              />
              <Mic className="ml-2 size-5 shrink-0 text-t4" aria-label="Diktieren" />
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
      )}
    </div>
  )
}

function ChatRow({ item, onPermission }: { item: ChatItem; onPermission: (c: 'yes' | 'always' | 'no') => void }) {
  switch (item.kind) {
    case 'user':
      return (
        <div className="ml-10 self-end rounded-[20px] rounded-br-md bg-active px-3.5 py-2.5 text-[15px] leading-snug text-t1">
          {item.text}
        </div>
      )
    case 'claude':
      return <p className="pr-4 text-[15px] leading-relaxed text-t1">{item.text}</p>
    case 'tool':
      return <ToolRow item={item} />
    case 'working':
      return (
        <div className="flex items-center gap-2 text-[14px] text-tone-blue">
          <span className="size-2 rounded-full bg-current pulse-soft" />
          {item.label} …
        </div>
      )
    case 'error':
      return (
        <div className="rounded-2xl border border-tone-red/25 bg-tone-red-soft p-3.5">
          <div className="text-[14px] font-semibold text-tone-red">API-Fehler · {item.type}</div>
          <p className="mt-0.5 text-[14px] text-t2">{item.text}</p>
          <p className="mt-2 text-[13px] text-t3">„weiter“ schickt die Runde neu los.</p>
        </div>
      )
    case 'permission':
      return (
        <div className="rounded-2xl border border-tone-orange/30 bg-tone-orange-soft p-3.5">
          <div className="text-[13px] font-semibold text-tone-orange">Claude möchte ausführen</div>
          <code className="mt-1.5 block rounded-lg bg-raised px-2.5 py-2 font-mono text-[13px] break-all text-t1">
            {item.command}
          </code>
          <div className="mt-1 text-[12px] text-t3">{item.why}</div>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <button
              type="button"
              onClick={() => onPermission('yes')}
              className="h-10 rounded-xl bg-t1 text-[14px] font-semibold text-bg active:opacity-80"
            >
              Erlauben
            </button>
            <button
              type="button"
              onClick={() => onPermission('no')}
              className="h-10 rounded-xl border border-hair bg-raised text-[14px] font-medium text-t1 active:bg-active"
            >
              Ablehnen
            </button>
            <button
              type="button"
              onClick={() => onPermission('always')}
              className="col-span-2 h-9 rounded-xl text-[13px] font-medium text-t2 active:bg-active"
            >
              Immer erlauben für <span className="font-mono">git push</span>
            </button>
          </div>
        </div>
      )
  }
}

function ToolRow({ item }: { item: Extract<ChatItem, { kind: 'tool' }> }) {
  const [open, setOpen] = useState(item.tool === 'Edit')
  const Icon = item.tool === 'Bash' ? SquareTerminal : item.tool === 'Edit' ? PencilLine : item.tool === 'Grep' ? Search : FileText
  const summary = item.output?.[item.output.length - 1]
  return (
    <div className="rounded-xl border border-hair bg-raised">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        aria-expanded={open}
        className="flex w-full items-center gap-2 px-3 py-2 text-left"
      >
        <Icon className="size-4 shrink-0 text-t3" />
        <span className="shrink-0 text-[13px] font-medium text-t2">{item.tool}</span>
        <span className="min-w-0 flex-1 truncate font-mono text-[12.5px] text-t3">{item.target}</span>
        <ChevronRight className={cn('size-4 shrink-0 text-t4 transition-transform', open && 'rotate-90')} />
      </button>
      {!open && summary && item.tool !== 'Read' && (
        <div className="truncate px-3 pb-2 font-mono text-[12px] text-t4">{summary}</div>
      )}
      {open && (
        <div className="overflow-x-auto border-t border-hair px-3 py-2 font-mono text-[12px] leading-[1.5]">
          {item.diff
            ? item.diff.map((d, i) => (
                <div
                  key={i}
                  className={cn(
                    'whitespace-pre',
                    d.sign === '+' && 'text-ansi-green',
                    d.sign === '-' && 'text-ansi-red',
                    d.sign === ' ' && 'text-t3',
                  )}
                >
                  {d.sign} {d.text}
                </div>
              ))
            : item.output?.map((l, i) => (
                <div key={i} className="whitespace-pre text-t2">
                  {l}
                </div>
              ))}
        </div>
      )}
    </div>
  )
}

export function Segmented<T extends string>({
  value,
  onChange,
  options,
}: {
  value: T
  onChange: (v: T) => void
  options: [T, string][]
}) {
  return (
    <div className="inline-flex rounded-lg bg-active p-0.5" role="tablist">
      {options.map(([v, label]) => (
        <button
          key={v}
          type="button"
          role="tab"
          aria-selected={value === v}
          onClick={() => onChange(v)}
          className={cn(
            'h-7 rounded-md px-3.5 text-[13px] font-medium transition-colors',
            value === v ? 'bg-raised text-t1 shadow-[0_1px_2px_rgb(0_0_0/0.08)]' : 'text-t3',
          )}
        >
          {label}
        </button>
      ))}
    </div>
  )
}

