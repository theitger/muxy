import { ChevronLeft, ChevronRight, Sparkle } from 'lucide-react'
import { useEffect, useState } from 'react'
import { cn } from '@/lib/utils'
import { PRBadge, SessionTile, prHelp } from '@/components/muxy'
import type { Session } from '@/lib/protocol'
import type { Muxy } from '@/lib/useMuxy'
import { ClaudeView } from './ClaudeView'
import { TerminalView } from './TerminalView'

/** One session: Muxy's tab bar on top, the tab's own view below. */
export function SessionScreen({
  session,
  muxy,
  urgentElsewhere,
  onBack,
}: {
  session: Session
  muxy: Muxy
  urgentElsewhere: number
  onBack: () => void
}) {
  const [tabId, setTabId] = useState(() => (session.tabs.find((t) => t.agent !== 'none') ?? session.tabs[0])?.id)
  const [history, setHistory] = useState(false)
  const tab = session.tabs.find((t) => t.id === tabId) ?? session.tabs[0]
  const { watch } = muxy

  // Tell Muxy which tab to stream; stop when leaving.
  useEffect(() => {
    if (!tab) return
    watch(tab.id, history)
    return () => watch(null)
  }, [tab?.id, history, watch])

  if (!tab) return null

  return (
    <div className="flex h-full flex-col bg-bg">
      <header className="border-b border-hair bg-surface px-2 pt-[calc(env(safe-area-inset-top,0px)+8px)] pb-2">
        <div className="flex items-center gap-2">
          <button type="button" onClick={onBack} className="flex h-10 items-center gap-0.5 rounded-lg pr-2 pl-1 text-[15px] text-t2 active:bg-active">
            <ChevronLeft className="size-5" />
            {urgentElsewhere > 0 && (
              <span className="grid size-5 place-items-center rounded-full bg-tone-orange-soft text-[11px] font-semibold text-tone-orange tabular-nums">
                {urgentElsewhere}
              </span>
            )}
          </button>
          <SessionTile agent={session.agent} attention={false} isGit={session.isGit} size={30} />
          <div className="min-w-0 flex-1">
            <div className="truncate text-[15px] font-semibold text-t1">{session.title}</div>
            <div className="truncate text-[12px] text-t4">{session.pr ? prHelp(session.pr.status) : session.subtitle}</div>
          </div>
          {session.pr && <PRBadge number={session.pr.number} status={session.pr.status} />}
        </div>

        {session.tabs.length > 1 && (
          <nav className="mt-2 flex gap-1 overflow-x-auto px-1" aria-label="Tabs">
            {session.tabs.map((t) => (
              <button
                key={t.id}
                type="button"
                onClick={() => setTabId(t.id)}
                aria-current={t.id === tab.id}
                className={cn(
                  'flex h-8 shrink-0 items-center gap-1.5 rounded-lg px-3 text-[13px] font-medium',
                  t.id === tab.id ? 'bg-active text-t1' : 'text-t3 active:bg-hover',
                )}
              >
                {t.kind === 'claude' ? <Sparkle className="size-3" strokeWidth={2.6} /> : <ChevronRight className="size-3" strokeWidth={2.6} />}
                {t.title}
                {t.attention && <span className="size-1.5 rounded-full bg-tone-orange" />}
              </button>
            ))}
          </nav>
        )}
      </header>

      {tab.kind === 'claude' ? (
        <ClaudeView
          key={tab.id}
          tab={tab}
          items={muxy.chats[tab.id]}
          screen={muxy.screens[tab.id]}
          history={history}
          onHistory={setHistory}
          onType={(text, enter) => muxy.type(tab.id, text, enter)}
          onKey={(k) => muxy.key(tab.id, k)}
        />
      ) : (
        <TerminalView
          key={tab.id}
          screen={muxy.screens[tab.id]}
          history={history}
          onHistory={setHistory}
          onType={(text, enter) => muxy.type(tab.id, text, enter)}
          onKey={(k) => muxy.key(tab.id, k)}
        />
      )}
    </div>
  )
}
