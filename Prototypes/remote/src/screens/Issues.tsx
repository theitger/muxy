import { ExternalLink } from 'lucide-react'
import { useMemo, useState } from 'react'
import { BottomSheet } from '@/components/BottomSheet'
import { AgentLogo } from '@/components/flow'
import { t } from '@/lib/i18n'
import type { Account, Issue } from '@/lib/protocol'
import { cn } from '@/lib/utils'

const READY = 'ready-for-agent'
const FILTER_KEY = 'muxy.issueFilter'

function readFilter(): string {
  try {
    return localStorage.getItem(FILTER_KEY) ?? ''
  } catch {
    return ''
  }
}

/** "6d", "3h", "1mo": an issue's age. */
function age(created?: number) {
  if (!created) return ''
  const s = Date.now() / 1000 - created
  const days = Math.floor(s / 86400)
  if (days >= 30) return t('%dmo', Math.floor(days / 30))
  if (days >= 1) return t('%dd', days)
  return t('%dh', Math.max(1, Math.floor(s / 3600)))
}

const short = (repo: string) => repo.split('/').at(-1) ?? repo

/**
 * The issues GitHub has assigned to you, as the Mac's hub lists them:
 * newest first, grouped by repository, filtered by one or ready for an
 * agent. A tap starts one on the Mac.
 */
export function Issues({
  issues,
  account,
  online,
  onStart,
}: {
  issues: Issue[]
  account: Account | null
  online: boolean
  onStart: (issue: Issue, agents: ('claude' | 'codex')[]) => void
}) {
  // "" all, "ready" only ready-for-agent, else a repository.
  const [filter, setFilter] = useState(readFilter)
  const [picked, setPicked] = useState<Issue | null>(null)
  const [scrolled, setScrolled] = useState(false)

  const choose = (value: string) => {
    const next = filter === value ? '' : value
    setFilter(next)
    try {
      localStorage.setItem(FILTER_KEY, next)
    } catch {
      /* private mode */
    }
  }

  const repos = useMemo(() => {
    const counts = new Map<string, number>()
    for (const i of issues) counts.set(i.repo, (counts.get(i.repo) ?? 0) + 1)
    return [...counts.entries()].sort((a, b) => b[1] - a[1])
  }, [issues])

  const shown = issues.filter((i) => (filter === 'ready' ? i.labels.includes(READY) : filter ? i.repo === filter : true))
  const groups = useMemo(() => {
    const order: string[] = []
    const by = new Map<string, Issue[]>()
    for (const i of shown) {
      if (!by.has(i.repo)) {
        order.push(i.repo)
        by.set(i.repo, [])
      }
      by.get(i.repo)!.push(i)
    }
    return order.map((repo) => ({ repo, issues: by.get(repo)! }))
  }, [shown])

  return (
    <div className="relative flex h-full flex-col bg-bg">
      <header
        className={cn(
          'absolute inset-x-0 top-0 z-20 pt-[env(safe-area-inset-top,0px)] transition-[background-color,border-color,backdrop-filter] duration-200',
          scrolled ? 'border-b border-hair bg-bg/80 backdrop-blur-xl backdrop-saturate-150' : 'border-b border-transparent',
        )}
      >
        <div className="flex h-11 items-center justify-center px-4">
          <span className={cn('text-[17px] font-semibold text-t1 transition-opacity duration-200', scrolled ? 'opacity-100' : 'opacity-0')}>{t('For you')}</span>
        </div>
      </header>

      <div
        onScroll={(e) => setScrolled(e.currentTarget.scrollTop > 36)}
        className="no-scrollbar flex-1 overflow-y-auto overscroll-y-contain pt-[calc(env(safe-area-inset-top,0px)+44px)] pb-[calc(env(safe-area-inset-bottom,0px)+96px)]"
      >
        <div className="flex items-end justify-between gap-3 px-4 pt-1 pb-2">
          <div className="min-w-0">
            <h1 className="text-[34px] leading-[41px] font-bold tracking-[0.01em] text-t1">{t('For you')}</h1>
            <div className="mt-0.5 text-[15px] text-t3">
              {issues.length === 1 ? t('1 issue assigned to you') : t('%d issues assigned to you', issues.length)}
            </div>
          </div>
          {account?.avatar && <img src={account.avatar} alt={account.name ?? account.login} className="mb-1 size-9 shrink-0 rounded-full border border-hair" />}
        </div>

        {/* Filters: swipe sideways through them. */}
        <div className="no-scrollbar flex gap-2 overflow-x-auto px-4 pt-1 pb-3">
          <Chip label={t('All')} count={issues.length} on={filter === ''} onTap={() => choose('')} />
          <Chip label={READY} count={issues.filter((i) => i.labels.includes(READY)).length} on={filter === 'ready'} onTap={() => choose('ready')} />
          {repos.length > 1 && repos.map(([repo, count]) => <Chip key={repo} label={short(repo)} count={count} on={filter === repo} onTap={() => choose(repo)} />)}
        </div>

        {!online && <p className="px-8 pb-2 text-[14px] text-tone-orange">{t('Mac unreachable, still trying')}</p>}

        {shown.length === 0 && (
          <p className="fade-in mt-20 px-10 text-center text-[15px] text-t3">{issues.length ? t('Nothing matches this filter.') : t('Nothing assigned to you.')}</p>
        )}

        {groups.map((group) => (
          <section key={group.repo} className="mt-4">
            {groups.length > 1 && (
              <h2 className="truncate px-8 pb-1.5 text-[13px] font-medium tracking-[0.02em] text-t3 uppercase">
                {short(group.repo)} <span className="text-t5">{group.issues.length}</span>
              </h2>
            )}
            <div className="mx-4 overflow-hidden rounded-[12px] bg-raised">
              {group.issues.map((issue, index) => (
                <button
                  key={issue.url}
                  type="button"
                  onClick={() => setPicked(issue)}
                  className={cn('row-press arrive flex w-full flex-col gap-1 px-4 py-3 text-left', index > 0 && 'border-t border-hair')}
                >
                  <span className="text-[16px] leading-snug font-medium text-t1">{issue.title}</span>
                  <span className="flex flex-wrap items-center gap-x-2 text-[13.5px] text-t3 tabular-nums">
                    <span>#{issue.number}</span>
                    <span className="text-t4">{age(issue.created)}</span>
                    {issue.labels.includes(READY) && <span className="text-tone-green">{READY}</span>}
                    {issue.labels.filter((l) => l.toLowerCase().includes('priority')).map((l) => (
                      <span key={l} className="text-tone-orange">
                        {l.replace('priority: ', '')}
                      </span>
                    ))}
                    {!issue.local && <span className="text-t4">{t('not cloned on the Mac')}</span>}
                  </span>
                </button>
              ))}
            </div>
          </section>
        ))}
      </div>

      <BottomSheet open={!!picked} onClose={() => setPicked(null)} title={picked ? `#${picked.number}` : ''}>
        {picked && (
          <div className="px-4 pt-2">
            <p className="px-1 text-[17px] leading-snug font-semibold text-t1">{picked.title}</p>
            <p className="mt-1 px-1 text-[14px] text-t3">
              {picked.repo}
              {picked.labels.length ? ` · ${picked.labels.join(', ')}` : ''}
            </p>
            {picked.local ? (
              <>
                <p className="mt-4 px-1 text-[13.5px] leading-snug text-t3">
                  {t('The Mac starts it in its own worktree, on a branch named after the issue, and asks the agent to close it from the pull request.')}
                </p>
                <div className="mt-3 overflow-hidden rounded-[12px] bg-raised">
                  <SheetRow
                    onTap={() => {
                      onStart(picked, ['claude'])
                      setPicked(null)
                    }}
                  >
                    <AgentLogo kind="claude" size={18} /> {t('Start %s', 'Claude')}
                  </SheetRow>
                  <SheetRow
                    border
                    onTap={() => {
                      onStart(picked, ['codex'])
                      setPicked(null)
                    }}
                  >
                    <AgentLogo kind="codex" size={18} /> {t('Start %s', 'Codex')}
                  </SheetRow>
                  <SheetRow
                    border
                    onTap={() => {
                      onStart(picked, ['claude', 'codex'])
                      setPicked(null)
                    }}
                  >
                    <span className="flex -space-x-1">
                      <AgentLogo kind="claude" size={18} />
                      <AgentLogo kind="codex" size={18} />
                    </span>
                    {t('Both, side by side')}
                  </SheetRow>
                </div>
              </>
            ) : (
              <p className="mt-4 px-1 text-[14px] text-t3">{t('This repository isn’t cloned on the Mac, so no session can start there.')}</p>
            )}
            <a href={picked.url} target="_blank" rel="noreferrer" className="mt-3 flex h-12 items-center justify-center gap-2 rounded-[12px] bg-raised text-[16px] text-t1 active:opacity-60">
              {t('Open on GitHub')} <ExternalLink className="size-4 text-t3" strokeWidth={2.2} />
            </a>
          </div>
        )}
      </BottomSheet>
    </div>
  )
}

function Chip({ label, count, on, onTap }: { label: string; count: number; on: boolean; onTap: () => void }) {
  return (
    <button
      type="button"
      onClick={onTap}
      className={cn(
        'flex h-[32px] shrink-0 items-center gap-1.5 rounded-full px-3.5 text-[14px] font-medium tabular-nums transition-colors duration-150',
        on ? 'bg-brand text-bg' : 'bg-raised text-t2',
      )}
    >
      {label}
      <span className={on ? 'text-bg/70' : 'text-t4'}>{count}</span>
    </button>
  )
}

function SheetRow({ children, onTap, border }: { children: React.ReactNode; onTap: () => void; border?: boolean }) {
  return (
    <button type="button" onClick={onTap} className={cn('row-press flex h-[52px] w-full items-center gap-3 px-4 text-left text-[16px] font-medium text-t1', border && 'border-t border-hair')}>
      {children}
    </button>
  )
}
