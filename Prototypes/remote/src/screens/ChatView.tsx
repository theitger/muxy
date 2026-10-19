import { ArrowDown, ChevronRight, FilePen, FileText, Search, SquareTerminal, Wrench } from 'lucide-react'
import { memo, useLayoutEffect, useRef, useState } from 'react'
import { cn } from '@/lib/utils'
import { Markdown } from '@/components/Markdown'
import { Live } from '@/components/muxy'
import { Tap } from '@/components/touch'
import { t } from '@/lib/i18n'
import { agentName, type ChatItem, type Session, type Tab } from '@/lib/protocol'

type Tool = Extract<ChatItem, { kind: 'tool' }>
type Entry = { kind: 'user' | 'agent'; text: string } | { kind: 'tools'; tools: Tool[] }

/** Runs of tool calls fold into one block, like the agents' own apps. */
function entries(items: ChatItem[]): Entry[] {
  const out: Entry[] = []
  for (const item of items) {
    if (item.kind === 'tool') {
      const last = out.at(-1)
      if (last?.kind === 'tools') last.tools.push(item)
      else out.push({ kind: 'tools', tools: [item] })
    } else out.push(item)
  }
  return out
}

/**
 * The agent as a conversation, read from its own log (Claude's or
 * Codex's). Its question becomes buttons; the terminal is one tap away for
 * everything else.
 */
export function ChatView({
  session,
  tab,
  items,
  onChoose,
}: {
  session: Session
  tab: Tab
  items?: ChatItem[]
  onChoose: (number: number) => void
}) {
  const scroller = useRef<HTMLDivElement>(null)
  const stick = useRef(true)
  const [behind, setBehind] = useState(false)
  const who = agentName(tab.agentKind)
  const list = items ? entries(items) : []
  const last = items?.at(-1)
  const footer = `${tab.agent}|${tab.choices?.length ?? 0}|${session.activity ?? ''}`

  // Follows what's new, unless you scrolled up to read.
  useLayoutEffect(() => {
    const el = scroller.current
    if (!el) return
    if (stick.current) el.scrollTop = el.scrollHeight
    else setBehind(true)
  }, [items?.length, last && JSON.stringify(last).length, footer])

  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      <div
        ref={scroller}
        onScroll={(e) => {
          const el = e.currentTarget
          const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 60
          stick.current = atBottom
          if (atBottom) setBehind(false)
        }}
        className="selectable flex-1 overflow-y-auto overscroll-y-contain px-4 pt-4 pb-6"
      >
        {items === undefined && tab.agent === 'working' ? null : items === undefined ? (
          <p className="fade-in mt-16 px-8 text-center text-[15px] leading-snug text-t4">
            {t('The conversation appears once %s does something in this session. Until then the terminal shows everything.', who)}
          </p>
        ) : list.length === 0 ? (
          <p className="fade-in mt-16 text-center text-[15px] text-t4">{t('Nothing in this conversation yet.')}</p>
        ) : (
          <div className="flex flex-col gap-4">
            {list.map((e, i) => (
              <EntryView key={i} entry={e} />
            ))}
          </div>
        )}

        {tab.agent === 'working' && (
          <div className="fade-in mt-4 flex items-center gap-2 text-[15px] text-t3">
            <span className="size-2 rounded-full bg-tone-blue pulse-soft" />
            <Live>{session.activity ?? t('%s is working', who)}</Live>
          </div>
        )}

        {tab.agent === 'blocked' && (
          <div className="arrive mt-5 overflow-hidden rounded-[14px] border border-tone-orange/25 bg-raised">
            <div className="bg-tone-orange-soft px-3.5 py-2.5 text-[14.5px] font-semibold text-tone-orange">{t('%s needs your decision', who)}</div>
            {session.lines && session.lines.length > 0 && (
              <div className="border-b border-hair px-3.5 py-2.5 font-mono text-[12.5px] leading-[1.45] text-t2">
                {session.lines.slice(-3).map((l, i) => (
                  <div key={i} className="break-words">
                    {l}
                  </div>
                ))}
              </div>
            )}
            {(tab.choices ?? []).map((c, i) => (
              <Tap
                key={c.number}
                onPress={() => onChoose(c.number)}
                className={cn('row-press min-h-[46px] w-full justify-start px-3.5 py-2 text-left text-[16px]', i > 0 && 'border-t border-hair', i === 0 ? 'font-semibold text-brand' : 'text-t1')}
              >
                <span className="leading-snug">{c.label}</span>
              </Tap>
            ))}
            {!tab.choices?.length && <div className="px-3.5 py-2.5 text-[14px] text-t3">{t('The question is in the terminal.')}</div>}
          </div>
        )}

        {tab.agent === 'failed' && (
          <div className="arrive mt-5 rounded-[14px] bg-tone-red-soft px-3.5 py-3">
            <div className="text-[15px] font-semibold text-tone-red">{t('The turn died on an error')}</div>
            <p className="mt-0.5 text-[14px] text-t2">{t('The details are in the terminal. Write “continue” and %s tries again.', who)}</p>
          </div>
        )}
      </div>

      {behind && (
        <div className="pointer-events-none absolute inset-x-0 bottom-3 z-10 flex justify-center">
          <Tap
            label={t('Jump to the end')}
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
  )
}

const EntryView = memo(
  function EntryView({ entry }: { entry: Entry }) {
    switch (entry.kind) {
      case 'user':
        return (
          <div className="arrive ml-12 self-end rounded-[20px] bg-bubble px-3.5 py-2 text-[16px] leading-[1.4] break-words whitespace-pre-wrap text-t1">
            {entry.text}
          </div>
        )
      case 'agent':
        return (
          <div className="arrive">
            <Markdown text={entry.text} />
          </div>
        )
      case 'tools':
        return <Tools tools={entry.tools} />
    }
  },
  (a, b) => JSON.stringify(a.entry) === JSON.stringify(b.entry),
)

const VERB: Record<string, string> = {
  Bash: t('Command'),
  Shell: t('Command'),
  Read: t('Read'),
  Edit: t('Edited'),
  MultiEdit: t('Edited'),
  Write: t('Wrote'),
  Grep: t('Searched'),
  Glob: t('Searched'),
  WebFetch: t('Fetched'),
  WebSearch: t('Searched'),
  Task: t('Subtask'),
  Agent: t('Subtask'),
  TodoWrite: 'Plan',
}

function iconFor(tool: string) {
  if (tool === 'Bash' || tool === 'Shell') return SquareTerminal
  if (tool === 'Edit' || tool === 'Write' || tool === 'MultiEdit') return FilePen
  if (tool === 'Grep' || tool === 'Glob' || tool === 'WebSearch') return Search
  if (tool === 'Read') return FileText
  return Wrench
}

/** Shorter paths: the file name carries it on a phone. */
function shortTarget(t: string) {
  if (/^[~/.]/.test(t) && !t.includes(' ')) {
    const parts = t.split('/')
    return parts.length > 2 ? `…/${parts.slice(-2).join('/')}` : t
  }
  return t.split('\n')[0]
}

function Tools({ tools }: { tools: Tool[] }) {
  const [open, setOpen] = useState(tools.length <= 2)
  const failed = tools.filter((t) => t.error).length
  if (!open) {
    const edits = tools.filter((t) => ['Edit', 'Write', 'MultiEdit'].includes(t.tool)).length
    const commands = tools.filter((t) => t.tool === 'Bash' || t.tool === 'Shell').length
    const parts = [
      tools.length === 1 ? t('1 step') : t('%d steps', tools.length),
      edits && t('%d edited', edits),
      commands && (commands === 1 ? t('1 command') : t('%d commands', commands)),
      failed && t('%d failed', failed),
    ].filter(Boolean)
    return (
      <button type="button" onClick={() => setOpen(true)} className="arrive flex items-center gap-1.5 self-start rounded-full bg-code py-1.5 pr-2.5 pl-3 text-[13.5px] text-t3 active:opacity-60">
        {parts.join(' · ')}
        <ChevronRight className="size-3.5" strokeWidth={2.4} />
      </button>
    )
  }
  return (
    <div className="arrive overflow-hidden rounded-[12px] border border-hair">
      {tools.map((t, i) => (
        <ToolRow key={t.id} tool={t} first={i === 0} />
      ))}
    </div>
  )
}

function ToolRow({ tool, first }: { tool: Tool; first: boolean }) {
  const [open, setOpen] = useState(false)
  const Icon = iconFor(tool.tool)
  const summary = tool.output?.filter((l) => l.trim() && !/^… \d+ more lines$/.test(l)).at(-1)
  const hasBody = !!(tool.diff?.length || tool.output?.length)
  return (
    <div className={cn(!first && 'border-t border-hair')}>
      <button type="button" disabled={!hasBody} onClick={() => setOpen(!open)} aria-expanded={open} className="row-press flex min-h-[40px] w-full items-center gap-2.5 px-3 text-left">
        <Icon className={cn('size-[15px] shrink-0', tool.error ? 'text-tone-red' : 'text-t3')} strokeWidth={2.2} />
        <span className="shrink-0 text-[13.5px] font-medium text-t2">{VERB[tool.tool] ?? tool.tool}</span>
        <span className="min-w-0 flex-1 truncate font-mono text-[12.5px] text-t3">{shortTarget(tool.target)}</span>
        {!tool.done && <span className="size-1.5 shrink-0 rounded-full bg-tone-blue pulse-soft" />}
        {hasBody && <ChevronRight className={cn('size-4 shrink-0 text-t5 transition-transform duration-200', open && 'rotate-90')} />}
      </button>
      {!open && summary && tool.error && <div className="truncate px-3 pb-2 pl-[38px] font-mono text-[12px] text-tone-red">{summary}</div>}
      {open && (
        <div className="fade-in no-scrollbar overflow-x-auto bg-code px-3 py-2 font-mono text-[12px] leading-[1.5]">
          {tool.target.includes('\n') && <div className="mb-1.5 whitespace-pre text-t2">{tool.target}</div>}
          {tool.diff?.map((d, i) => (
            <div key={`d${i}`} className={cn('whitespace-pre', d.sign === '+' && 'text-ansi-green', d.sign === '-' && 'text-ansi-red', d.sign === ' ' && 'text-t3')}>
              {d.sign} {d.text}
            </div>
          ))}
          {tool.output?.map((l, i) => (
            <div key={`o${i}`} className={cn('whitespace-pre', tool.error ? 'text-tone-red' : 'text-t2')}>
              {l || ' '}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
