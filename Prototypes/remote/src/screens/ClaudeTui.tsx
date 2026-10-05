import { cn } from '@/lib/utils'
import type { ChatItem } from '@/data'

/**
 * The same conversation as Claude Code draws it in the terminal: ⏺ for
 * Claude and its tools, ⎿ for results, the permission dialog, the prompt
 * box, the mode line and the user's ccstatusline (model | ctx | branch |
 * changes in cyan, bright black, magenta, yellow).
 */
export function ClaudeTui({ chat, branch, working }: { chat: ChatItem[]; branch: string; working: boolean }) {
  const asking = chat.some((i) => i.kind === 'permission')
  return (
    <div className="font-mono text-[12.5px] leading-[1.4] text-term">
      {chat.map((item, i) => (
        <TuiItem key={i} item={item} />
      ))}

      {!asking && (
        <div className="mt-3">
          <div className="border-t border-ansi-dim/50" />
          <div className="py-0.5">
            <span className="text-ansi-dim">&gt; </span>
            {!working && <span className="caret inline-block h-[1.1em] w-[0.55em] translate-y-[0.18em] bg-term" />}
          </div>
          <div className="border-t border-ansi-dim/50" />
          <div className="mt-0.5 text-ansi-magenta">
            {'  '}⏵⏵ auto mode on <span className="text-ansi-dim">(shift+tab to cycle)</span>
          </div>
        </div>
      )}
      <div className="mt-0.5 break-all">
        <span className="text-ansi-cyan">Model: Opus 5.5 (1M context)</span>
        <span className="text-ansi-dim"> | </span>
        <span className="text-ansi-dim">Ctx: 48.2k</span>
        <span className="text-ansi-dim"> | </span>
        <span className="text-ansi-magenta">⎇ {branch}</span>
        <span className="text-ansi-dim"> | </span>
        <span className="text-ansi-yellow">(+42,-10)</span>
      </div>
    </div>
  )
}

function TuiItem({ item }: { item: ChatItem }) {
  switch (item.kind) {
    case 'user':
      return (
        <div className="mt-3 -mx-1 rounded bg-active px-1 text-t3">
          &gt; {item.text}
        </div>
      )
    case 'claude':
      return (
        <div className="mt-3 flex">
          <span className="w-[2ch] shrink-0">⏺</span>
          <span className="min-w-0">{item.text}</span>
        </div>
      )
    case 'tool': {
      const name = item.tool === 'Edit' ? 'Update' : item.tool === 'Grep' ? 'Search' : item.tool
      const added = item.diff?.filter((d) => d.sign === '+').length ?? 0
      const removed = item.diff?.filter((d) => d.sign === '-').length ?? 0
      const result =
        item.tool === 'Read'
          ? `Read ${item.output?.[0]?.replace(' Zeilen', ' lines')}`
          : item.tool === 'Edit'
            ? `Updated ${item.target} with ${added} additions and ${removed} removals`
            : item.output?.[item.output.length - 1]
      return (
        <div className="mt-3">
          <div className="flex">
            <span className="w-[2ch] shrink-0 text-ansi-green">⏺</span>
            <span className="min-w-0 break-all">
              <span className="font-bold">{name}</span>({item.target})
            </span>
          </div>
          {result && (
            <div className="flex">
              <span className="w-[5ch] shrink-0 text-ansi-dim">{'  ⎿  '}</span>
              <span className="min-w-0 break-all text-ansi-dim">{result}</span>
            </div>
          )}
          {item.diff?.map((d, i) => (
            <div
              key={i}
              className={cn(
                'ml-[5ch] break-all whitespace-pre-wrap',
                d.sign === '+' && 'bg-tone-green-soft text-tone-green',
                d.sign === '-' && 'bg-tone-red-soft text-tone-red',
                d.sign === ' ' && 'text-ansi-dim',
              )}
            >
              {d.sign} {d.text}
            </div>
          ))}
        </div>
      )
    }
    case 'working':
      return (
        <div className="mt-3 text-claude">
          <span className="pulse-soft">✻</span> {item.label}… <span className="text-ansi-dim">(38s · esc to interrupt)</span>
        </div>
      )
    case 'error':
      return (
        <div className="flex">
          <span className="w-[5ch] shrink-0 text-ansi-dim">{'  ⎿  '}</span>
          <span className="text-ansi-red">API Error: 429 {item.type}_error</span>
        </div>
      )
    case 'permission':
      return (
        <div className="mt-3 rounded-md border border-claude/60 px-2 py-1.5">
          <div className="font-bold text-claude">Bash command</div>
          <div className="mt-2 pl-[2ch] break-all">{item.command}</div>
          <div className="pl-[2ch] text-ansi-dim">Push branch to remote</div>
          <div className="mt-2">Do you want to proceed?</div>
          <div className="text-claude">❯ 1. Yes</div>
          <div className="pl-[2ch]">2. Yes, and don't ask again for git push commands in ~/muxy</div>
          <div className="pl-[2ch]">3. No, and tell Claude what to do differently <span className="text-ansi-dim">(esc)</span></div>
        </div>
      )
  }
}
