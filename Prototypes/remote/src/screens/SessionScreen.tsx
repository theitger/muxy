import { ChevronLeft, ChevronRight, Ellipsis, MessageSquare, SquareTerminal } from 'lucide-react'
import { AgentLogo, Facts, StepButton } from '@/components/flow'
import { actionable } from '@/lib/protocol'
import { useEffect, useState } from 'react'
import { cn } from '@/lib/utils'
import { BottomSheet } from '@/components/BottomSheet'
import { Composer } from '@/components/Composer'
import { Switch, status, toneText } from '@/components/muxy'
import { t } from '@/lib/i18n'
import { agentName, type Session } from '@/lib/protocol'
import type { Muxy } from '@/lib/useMuxy'
import { ChatView } from './ChatView'
import { TerminalView, store, stored } from './TerminalView'

/** One session: a navigation bar, its tabs, and the tab as chat or terminal. */
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
  const [tabId, setTabId] = useState(() => (session.tabs.find((t) => t.kind === 'agent') ?? session.tabs[0])?.id)
  const tab = session.tabs.find((t) => t.id === tabId) ?? session.tabs[0]
  const [mode, setMode] = useState<'chat' | 'terminal'>(tab?.kind === 'agent' ? 'chat' : 'terminal')
  const [history, setHistory] = useState(false)
  const [wrap, setWrap] = useState(() => stored('muxy.wrap', '1') === '1')
  const [options, setOptions] = useState(false)
  const { watch } = muxy
  const items = tab ? muxy.chats[tab.id] : undefined

  // Tell Muxy which tab to stream; stop when leaving.
  useEffect(() => {
    if (!tab) return
    watch(tab.id, history)
    return () => watch(null)
  }, [tab?.id, history, watch])

  if (!tab) return null
  const st = status(session)
  const who = agentName(tab.agentKind)
  const showChat = tab.kind === 'agent' && mode === 'chat'
  const type = (text: string, enter: boolean) => muxy.type(tab.id, text, enter)
  const key = (k: string) => muxy.key(tab.id, k)

  return (
    <div className="flex h-full flex-col bg-bg">
      <header className="relative z-20 border-b border-hair bg-surface/85 pt-[env(safe-area-inset-top,0px)] backdrop-blur-xl backdrop-saturate-150">
        <div className="grid h-11 grid-cols-[auto_1fr_auto] items-center gap-1 px-1.5">
          <button type="button" onClick={onBack} aria-label={t('Back to sessions')} className="flex h-11 items-center pr-2 text-brand active:opacity-40">
            <ChevronLeft className="size-[30px]" strokeWidth={2} />
            {urgentElsewhere > 0 ? (
              <span className="-ml-0.5 grid h-[20px] min-w-[20px] place-items-center rounded-full bg-tone-orange px-1.5 text-[12px] font-semibold text-white tabular-nums">{urgentElsewhere}</span>
            ) : (
              <span className="-ml-0.5 text-[17px]">Sessions</span>
            )}
          </button>
          <div className="min-w-0 text-center">
            <div className="truncate text-[16px] leading-tight font-semibold text-t1">{session.title}</div>
            <div className={cn('truncate text-[12px] leading-tight', toneText[st.tone])}>{st.text}</div>
          </div>
          <div className="flex items-center justify-end">
            {tab.kind === 'agent' && (
              <button
                type="button"
                onClick={() => setMode(mode === 'chat' ? 'terminal' : 'chat')}
                aria-label={mode === 'chat' ? t('Show terminal') : t('Show chat')}
                className="grid size-11 place-items-center text-brand active:opacity-40"
              >
                {mode === 'chat' ? <SquareTerminal className="size-[22px]" strokeWidth={2} /> : <MessageSquare className="size-[22px]" strokeWidth={2} />}
              </button>
            )}
            {!showChat && (
              <button type="button" onClick={() => setOptions(true)} aria-label={t('View')} className="grid size-11 place-items-center text-brand active:opacity-40">
                <Ellipsis className="size-[22px]" strokeWidth={2.2} />
              </button>
            )}
          </div>
        </div>

        {session.tabs.length > 1 && (
          <nav className="no-scrollbar flex gap-1.5 overflow-x-auto px-3 pb-2" aria-label="Tabs">
            {session.tabs.map((t) => (
              <button
                key={t.id}
                type="button"
                onClick={() => {
                  setTabId(t.id)
                  setMode(t.kind === 'agent' ? 'chat' : 'terminal')
                }}
                aria-current={t.id === tab.id}
                className={cn(
                  'flex h-[30px] shrink-0 items-center gap-1.5 rounded-full px-3 text-[14px] transition-colors duration-150',
                  t.id === tab.id ? 'bg-t1 font-medium text-bg' : 'bg-active text-t2',
                )}
              >
                {t.kind === 'agent' && t.agentKind ? <AgentLogo kind={t.agentKind} size={13} /> : <ChevronRight className="size-3" strokeWidth={2.6} />}
                {t.title}
                {t.attention && t.id !== tab.id && <span className="size-1.5 rounded-full bg-tone-orange" />}
              </button>
            ))}
          </nav>
        )}

        {(actionable(session.next?.kind) || session.proof || session.collisions?.length || session.quorum) && (
          <div className="flex items-center gap-3 border-t border-hair px-4 py-2">
            <div className="min-w-0 flex-1">
              {actionable(session.next?.kind) && <div className="text-[13px] font-medium text-t2">{t('Next step')}</div>}
              <Facts session={session} />
            </div>
            <StepButton session={session} onStep={(s) => s.next && muxy.step(s.id, s.next.kind)} size="sm" />
          </div>
        )}
      </header>

      {showChat ? (
        <>
          <ChatView key={tab.id} session={session} tab={tab} items={items} onChoose={(n) => muxy.choose(tab.id, n)} />
          <Composer
            busy={tab.agent === 'working'}
            onType={type}
            onKey={key}
            placeholder={
              tab.agent === 'working'
                ? t("Message for when it's done")
                : tab.agent === 'blocked'
                  ? t('Or write what to do instead')
                  : tab.agent === 'failed'
                    ? t('“continue” restarts the turn')
                    : t('Reply to %s', who)
            }
          />
        </>
      ) : (
        <TerminalView
          key={tab.id}
          screen={muxy.screens[tab.id]}
          wrap={wrap}
          busy={tab.agent === 'working'}
          commands={tab.kind === 'shell' ? muxy.history : undefined}
          onType={type}
          onKey={key}
        />
      )}

      <BottomSheet open={options} onClose={() => setOptions(false)} title={t('View')} closeLabel={t('Done')}>
        <div className="mx-4 mt-2 overflow-hidden rounded-[12px] bg-raised">
          <Option label={t('Wrap lines')} hint={t('Long lines fit the screen.')}>
            <Switch
              label={t('Wrap lines')}
              on={wrap}
              onChange={(on) => {
                setWrap(on)
                store('muxy.wrap', on ? '1' : '0')
              }}
            />
          </Option>
          <Option label={t('Full history')} hint={t('Also loads what scrolled off the top.')} border>
            <Switch label={t('Full history')} on={history} onChange={setHistory} />
          </Option>
        </div>
        <p className="px-8 pt-2 text-[13px] text-t4">{t('Pinch with two fingers to change the text size.')}</p>
      </BottomSheet>
    </div>
  )
}

function Option({ label, hint, border, children }: { label: string; hint: string; border?: boolean; children: React.ReactNode }) {
  return (
    <div className={cn('flex min-h-[56px] items-center gap-3 px-4 py-2', border && 'border-t border-hair')}>
      <div className="min-w-0 flex-1">
        <div className="text-[16px] text-t1">{label}</div>
        <div className="text-[13px] text-t3">{hint}</div>
      </div>
      {children}
    </div>
  )
}
