import { useCallback, useEffect, useRef, useState } from 'react'
import { CircleDot, SquareTerminal } from 'lucide-react'
import { Stack } from '@/components/Stack'
import { cn } from '@/lib/utils'
import { Issues } from '@/screens/Issues'
import { wantsYou } from '@/components/muxy'
import { t } from '@/lib/i18n'
import { useMuxy } from '@/lib/useMuxy'
import { useVisualViewport } from '@/lib/viewport'
import { Home } from '@/screens/Home'
import { NewSession } from '@/screens/NewSession'
import { Pair } from '@/screens/Pair'
import { SessionScreen } from '@/screens/SessionScreen'

export default function App() {
  const muxy = useMuxy()
  useVisualViewport()
  const [open, setOpen] = useState<string | null>(null)
  const [animatePop, setAnimatePop] = useState(true)
  const [everConnected, setEverConnected] = useState(false)
  const [creating, setCreating] = useState(false)
  const [awaitingNew, setAwaitingNew] = useState(false)
  const [toast, setToast] = useState<string | null>(null)
  const [tab, setTab] = useState<'sessions' | 'issues'>('sessions')
  const ownPop = useRef<'animate' | 'still' | null>(null)

  useEffect(() => {
    if (muxy.state === 'open') setEverConnected(true)
  }, [muxy.state])

  // Back: our button and swipe animate themselves; the system's own back
  // gesture in Safari already drew one.
  useEffect(() => {
    const onPop = () => {
      setAnimatePop(ownPop.current === 'animate')
      ownPop.current = null
      setOpen(null)
    }
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  const go = useCallback((id: string) => {
    history.pushState({ session: id }, '')
    setOpen(id)
  }, [])
  const back = useCallback(() => {
    ownPop.current = 'animate'
    history.back()
  }, [])
  const swipedBack = useCallback(() => {
    ownPop.current = 'still'
    history.back()
  }, [])

  // A session started from here: straight into it.
  useEffect(() => {
    if (!awaitingNew || !muxy.opened) return
    setAwaitingNew(false)
    if (muxy.opened.session) go(muxy.opened.session)
    else setToast(muxy.opened.error ? t("Couldn't start: %s", muxy.opened.error) : t("Couldn't start the session"))
  }, [muxy.opened])

  useEffect(() => {
    if (!toast) return
    const t = setTimeout(() => setToast(null), 4000)
    return () => clearTimeout(t)
  }, [toast])

  // The session went away on the Mac while open here.
  // (A new one appears a moment after it was opened: only once seen.)
  const session = open ? muxy.sessions.find((s) => s.id === open) : undefined
  const seen = useRef<string | null>(null)
  useEffect(() => {
    if (session) seen.current = session.id
    else if (open && seen.current === open && muxy.state === 'open') back()
  }, [open, session, muxy.state])

  if (!muxy.paired || muxy.state === 'rejected' || !everConnected) {
    return (
      <div className="app-frame mx-auto max-w-[560px]">
        <Pair paired={muxy.paired} state={muxy.state} />
      </div>
    )
  }

  const urgent = muxy.sessions.filter(wantsYou)

  return (
    <div className="app-frame mx-auto max-w-[560px] overflow-hidden">
      <Stack
        base={
          <div className="relative h-full">
            {tab === 'sessions' ? (
              <Home
                sessions={muxy.sessions}
                online={muxy.state === 'open'}
                onOpen={go}
                onChoose={muxy.choose}
                onStep={(s) => s.next && muxy.step(s.id, s.next.kind)}
                onNew={() => {
                  muxy.loadRepos()
                  setCreating(true)
                }}
              />
            ) : (
              <Issues
                issues={muxy.issues}
                account={muxy.account}
                online={muxy.state === 'open'}
                onStart={(issue, agents) => {
                  setAwaitingNew(true)
                  muxy.startIssue(issue, agents)
                  setTab('sessions')
                }}
              />
            )}
            <TabBar tab={tab} onTab={setTab} waiting={urgent.length} />
          </div>
        }
        pageKey={session ? session.id : null}
        page={session ? <SessionScreen key={session.id} session={session} muxy={muxy} urgentElsewhere={urgent.filter((u) => u.id !== session.id).length} onBack={back} /> : null}
        animate={animatePop}
        onSwipeBack={swipedBack}
      />

      <NewSession
        open={creating}
        repos={muxy.repos}
        recent={muxy.recent}
        onClose={() => setCreating(false)}
        onStart={(spec) => {
          setCreating(false)
          setAwaitingNew(true)
          muxy.start(spec)
        }}
      />

      {muxy.state !== 'open' && (
        <div className="fade-in pointer-events-none absolute inset-x-0 top-[calc(env(safe-area-inset-top,0px)+50px)] z-40 flex justify-center">
          <div className="flex items-center gap-2 rounded-full bg-t1/90 px-3.5 py-2 text-[13.5px] font-medium text-bg shadow-lg backdrop-blur">
            <span className="size-3.5 animate-spin rounded-full border-2 border-bg/40 border-t-bg" />
            {t('Reconnecting')}
          </div>
        </div>
      )}

      {toast && (
        <div className="arrive absolute inset-x-4 top-[calc(env(safe-area-inset-top,0px)+52px)] z-40 rounded-[14px] bg-t1 px-4 py-3 text-[15px] text-bg shadow-xl" role="alert" onClick={() => setToast(null)}>
          {toast}
        </div>
      )}
    </div>
  )
}

/** iOS's tab bar: the two places the phone has, with what waits in each. */
function TabBar({ tab, onTab, waiting }: { tab: 'sessions' | 'issues'; onTab: (tab: 'sessions' | 'issues') => void; waiting: number }) {
  const item = (id: 'sessions' | 'issues', label: string, Icon: typeof SquareTerminal, badge: number) => (
    <button
      type="button"
      onClick={() => onTab(id)}
      aria-current={tab === id}
      className={cn('relative flex flex-1 flex-col items-center gap-0.5 pt-1.5 text-[10.5px] font-medium transition-colors', tab === id ? 'text-t1' : 'text-t4')}
    >
      <Icon className="size-[24px]" strokeWidth={tab === id ? 2.2 : 1.8} />
      {label}
      {badge > 0 && (
        <span className="absolute top-0.5 left-[calc(50%+6px)] grid h-[17px] min-w-[17px] place-items-center rounded-full bg-tone-orange px-1 text-[11px] font-semibold text-white tabular-nums">
          {badge}
        </span>
      )}
    </button>
  )
  return (
    <nav className="absolute inset-x-0 bottom-0 z-30 flex border-t border-hair bg-bg/85 pb-[env(safe-area-inset-bottom,0px)] backdrop-blur-xl backdrop-saturate-150">
      {item('sessions', t('Sessions'), SquareTerminal, waiting)}
      {item('issues', t('For you'), CircleDot, 0)}
    </nav>
  )
}
