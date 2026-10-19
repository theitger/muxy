import { ChevronRight, Plus, WifiOff } from 'lucide-react'
import { useState } from 'react'
import { cn } from '@/lib/utils'
import { Ago, Live, PRBadge, SessionTile, status, toneText, urgency, wantsYou } from '@/components/muxy'
import { agentName, type Session } from '@/lib/protocol'

/**
 * Muxy's sidebar as the phone's home: what waits on you on top, answerable
 * right there; then what runs; then everything else by repository.
 */
export function Home({
  sessions,
  online,
  onOpen,
  onNew,
  onChoose,
}: {
  sessions: Session[]
  online: boolean
  onOpen: (id: string) => void
  onNew: () => void
  onChoose: (tab: string, number: number) => void
}) {
  const [scrolled, setScrolled] = useState(false)
  const waiting = sessions.filter(wantsYou).sort((a, b) => urgency(a) - urgency(b))
  const running = sessions.filter((s) => !wantsYou(s) && s.agent === 'working')
  const rest = sessions.filter((s) => !wantsYou(s) && s.agent !== 'working')
  const groups = [...new Set(rest.map((s) => s.group))]

  return (
    <div className="relative flex h-full flex-col bg-bg">
      {/* The compact bar: the title moves up here once the large one scrolls away. */}
      <header
        className={cn(
          'absolute inset-x-0 top-0 z-20 pt-[env(safe-area-inset-top,0px)] transition-[background-color,border-color,backdrop-filter] duration-200',
          scrolled ? 'border-b border-hair bg-bg/80 backdrop-blur-xl backdrop-saturate-150' : 'border-b border-transparent',
        )}
      >
        <div className="flex h-11 items-center justify-between px-4">
          <span className="w-10" />
          <span className={cn('text-[17px] font-semibold text-t1 transition-opacity duration-200', scrolled ? 'opacity-100' : 'opacity-0')}>Sessions</span>
          <button
            type="button"
            onClick={onNew}
            aria-label="Neue Session"
            className="grid size-10 place-items-center rounded-full text-brand transition-opacity active:opacity-40"
          >
            <Plus className="size-[26px]" strokeWidth={2.2} />
          </button>
        </div>
      </header>

      <div
        onScroll={(e) => setScrolled(e.currentTarget.scrollTop > 36)}
        className="no-scrollbar flex-1 overflow-y-auto overscroll-y-contain pt-[calc(env(safe-area-inset-top,0px)+44px)] pb-[calc(env(safe-area-inset-bottom,0px)+24px)]"
      >
        <div className="px-4 pt-1 pb-2">
          <h1 className="text-[34px] leading-[41px] font-bold tracking-[0.01em] text-t1">Sessions</h1>
          <Summary online={online} waiting={waiting.length} running={running.length} />
        </div>

        {sessions.length === 0 && (
          <div className="fade-in mt-24 flex flex-col items-center gap-3 px-10 text-center">
            <p className="text-[17px] font-semibold text-t1">Keine offenen Sessions</p>
            <p className="text-[15px] leading-snug text-t3">Starte eine auf dem Mac, mit einem Agent und einer Aufgabe.</p>
            <button type="button" onClick={onNew} className="mt-2 h-11 rounded-full bg-brand px-5 text-[16px] font-semibold text-white active:opacity-70">
              Neue Session
            </button>
          </div>
        )}

        {waiting.length > 0 && (
          <Section title="Wartet auf dich">
            <div className="flex flex-col gap-2.5 px-4">
              {waiting.map((s) => (
                <WaitingCard key={s.id} session={s} onOpen={onOpen} onChoose={onChoose} />
              ))}
            </div>
          </Section>
        )}

        {running.length > 0 && (
          <Section title="Läuft">
            <List>
              {running.map((s) => (
                <Row key={s.id} session={s} onOpen={onOpen} showGroup />
              ))}
            </List>
          </Section>
        )}

        {groups.map((g) => (
          <Section key={g} title={g}>
            <List>
              {rest
                .filter((s) => s.group === g)
                .map((s) => (
                  <Row key={s.id} session={s} onOpen={onOpen} />
                ))}
            </List>
          </Section>
        ))}
      </div>
    </div>
  )
}

function Summary({ online, waiting, running }: { online: boolean; waiting: number; running: number }) {
  if (!online)
    return (
      <div className="mt-0.5 flex items-center gap-1.5 text-[15px] text-tone-orange">
        <WifiOff className="size-4" strokeWidth={2.2} /> Mac nicht erreichbar, versuche es weiter
      </div>
    )
  const parts = [waiting && `${waiting} ${waiting === 1 ? 'wartet' : 'warten'} auf dich`, running && `${running} ${running === 1 ? 'läuft' : 'laufen'}`].filter(Boolean)
  return <div className="mt-0.5 text-[15px] text-t3">{parts.length ? parts.join(' · ') : 'Alles ruhig'}</div>
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="mt-6">
      <h2 className="truncate px-8 pb-1.5 text-[13px] font-medium tracking-[0.02em] text-t3 uppercase">{title}</h2>
      {children}
    </section>
  )
}

/** iOS's inset grouped list. */
function List({ children }: { children: React.ReactNode }) {
  return <div className="mx-4 overflow-hidden rounded-[12px] bg-raised [&>*+*>div:last-child]:border-t [&>*+*>div:last-child]:border-hair">{children}</div>
}

function Row({ session, onOpen, showGroup }: { session: Session; onOpen: (id: string) => void; showGroup?: boolean }) {
  const st = status(session)
  return (
    <button type="button" onClick={() => onOpen(session.id)} className="row-press arrive flex w-full items-stretch pl-3.5 text-left">
      <div className="flex items-center py-2.5 pr-3">
        <SessionTile agent={session.agent} attention={session.attention} isGit={session.isGit} size={34} />
      </div>
      <div className="flex min-h-[60px] min-w-0 flex-1 items-center gap-2 pr-3">
        <div className="min-w-0 flex-1 py-2">
          <div className="truncate text-[16px] font-medium text-t1">{session.title}</div>
          <div className={cn('truncate text-[14px]', toneText[st.tone])}>
            {showGroup && <span className="text-t3">{session.group} · </span>}
            {st.live ? <Live>{st.text}</Live> : st.text}
          </div>
        </div>
        {session.pr && <PRBadge number={session.pr.number} status={session.pr.status} />}
        <ChevronRight className="size-[18px] shrink-0 text-t5" strokeWidth={2.4} />
      </div>
    </button>
  )
}

/** A session that waits: what it asks, and the answers, one tap away. */
function WaitingCard({ session, onOpen, onChoose }: { session: Session; onOpen: (id: string) => void; onChoose: (tab: string, number: number) => void }) {
  const st = status(session)
  const tab = session.tabs.find((t) => t.choices?.length) ?? session.tabs.find((t) => t.attention || t.agent !== 'none') ?? session.tabs[0]
  const choices = tab?.choices ?? []
  const [sent, setSent] = useState<number | null>(null)
  const preview = session.lines?.filter((l) => l.trim()).slice(-3) ?? []

  return (
    <div className="arrive overflow-hidden rounded-[14px] bg-raised">
      <button type="button" onClick={() => onOpen(session.id)} className="row-press flex w-full gap-3 px-3.5 pt-3 pb-2.5 text-left">
        <SessionTile agent={session.agent} attention={session.attention} isGit={session.isGit} size={34} />
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline gap-2">
            <span className="min-w-0 flex-1 truncate text-[16px] font-semibold text-t1">{session.title}</span>
            <span className="shrink-0 text-[13px] text-t4">
              <Ago since={tab?.since} />
            </span>
          </div>
          <div className="truncate text-[13.5px] text-t3">
            {agentName(session.agentKind)} · {session.group}
          </div>
          <div className={cn('mt-1 text-[14.5px] font-medium', toneText[st.tone])}>{st.text}</div>
        </div>
      </button>

      {preview.length > 0 && (
        <div className="mx-3.5 mb-2.5 rounded-[9px] bg-code px-2.5 py-2 font-mono text-[12px] leading-[1.45] text-t2">
          {preview.map((l, i) => (
            <div key={i} className="truncate">
              {l}
            </div>
          ))}
        </div>
      )}

      {choices.length > 0 && tab && (
        <div className="border-t border-hair">
          {choices.map((c, i) => (
            <button
              key={c.number}
              type="button"
              disabled={sent !== null}
              onClick={() => {
                setSent(c.number)
                onChoose(tab.id, c.number)
                // Still asking after a while: let it be answered again.
                setTimeout(() => setSent(null), 5000)
              }}
              className={cn(
                'row-press flex min-h-[46px] w-full items-center gap-3 px-3.5 text-left text-[16px] disabled:opacity-50',
                i > 0 && 'border-t border-hair',
                i === 0 ? 'font-semibold text-brand' : 'text-t1',
              )}
            >
              <span className="min-w-0 flex-1 leading-snug">{c.label}</span>
              {sent === c.number && <span className="size-4 animate-spin rounded-full border-2 border-t3 border-t-transparent" />}
            </button>
          ))}
        </div>
      )}

      {choices.length === 0 && (
        <button type="button" onClick={() => onOpen(session.id)} className="row-press flex h-11 w-full items-center justify-center border-t border-hair text-[16px] text-brand">
          {session.agent === 'failed' ? 'Ansehen und weitermachen' : session.agent === 'blocked' ? 'Antworten' : 'Ansehen'}
        </button>
      )}
    </div>
  )
}
