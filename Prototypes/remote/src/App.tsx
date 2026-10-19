import { useCallback, useEffect, useRef, useState } from 'react'
import { Stack } from '@/components/Stack'
import { wantsYou } from '@/components/muxy'
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
    else setToast(muxy.opened.error ? `Konnte nicht starten: ${muxy.opened.error}` : 'Konnte die Session nicht starten')
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
          <Home
            sessions={muxy.sessions}
            online={muxy.state === 'open'}
            onOpen={go}
            onChoose={muxy.choose}
            onNew={() => {
              muxy.loadRepos()
              setCreating(true)
            }}
          />
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
            Verbinde neu
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
