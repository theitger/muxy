import { useEffect, useState } from 'react'
import { useMuxy } from '@/lib/useMuxy'
import { Pair } from '@/screens/Pair'
import { SessionScreen } from '@/screens/SessionScreen'
import { Sessions, wantsYou } from '@/screens/Sessions'

export default function App() {
  const muxy = useMuxy()
  const [open, setOpen] = useState<string | null>(null)
  const [everConnected, setEverConnected] = useState(false)
  const [awaitingNew, setAwaitingNew] = useState(false)

  useEffect(() => {
    if (muxy.state === 'open') setEverConnected(true)
  }, [muxy.state])

  // A session opened from the phone: go straight into it.
  useEffect(() => {
    if (awaitingNew && muxy.opened?.session) {
      history.pushState({ session: muxy.opened.session }, '')
      setOpen(muxy.opened.session)
      setAwaitingNew(false)
    }
  }, [muxy.opened, awaitingNew])

  // Back navigation with the phone's own gesture / button.
  useEffect(() => {
    const onPop = () => setOpen(null)
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  function go(id: string) {
    history.pushState({ session: id }, '')
    setOpen(id)
  }

  if (!muxy.paired || muxy.state === 'rejected' || !everConnected) {
    return (
      <div className="mx-auto h-full max-w-[560px]">
        <Pair paired={muxy.paired} state={muxy.state} />
      </div>
    )
  }

  const session = open ? muxy.sessions.find((s) => s.id === open) : undefined
  const urgent = muxy.sessions.filter(wantsYou)

  return (
    <div className="mx-auto h-full max-w-[560px] overflow-hidden">
      {session ? (
        <SessionScreen
          key={session.id}
          session={session}
          muxy={muxy}
          urgentElsewhere={urgent.filter((u) => u.id !== session.id).length}
          onBack={() => history.back()}
        />
      ) : (
        <Sessions
          sessions={muxy.sessions}
          recent={muxy.recent}
          online={muxy.state === 'open'}
          onOpen={go}
          onNew={(dir) => {
            setAwaitingNew(true)
            muxy.open(dir)
          }}
        />
      )}
    </div>
  )
}
