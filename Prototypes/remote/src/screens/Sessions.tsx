import { FolderGit2, Plus, ShieldCheck, WifiOff } from 'lucide-react'
import { useState } from 'react'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { PRBadge, SessionTile } from '@/components/muxy'
import type { Session } from '@/lib/protocol'

export const wantsYou = (s: Session) => s.agent === 'blocked' || s.agent === 'failed' || s.attention

/** Muxy's sidebar as the phone's home screen — whatever wants you on top. */
export function Sessions({
  sessions,
  recent,
  online,
  onOpen,
  onNew,
}: {
  sessions: Session[]
  recent: string[]
  online: boolean
  onOpen: (id: string) => void
  onNew: (directory: string) => void
}) {
  const [picking, setPicking] = useState(false)
  const urgent = sessions.filter(wantsYou)
  const groups = [...new Set(sessions.map((s) => s.group))]
  const folders = [...new Set(['~', ...recent])]

  return (
    <div className="flex h-full flex-col bg-surface">
      <header className="sticky top-0 z-10 flex items-center justify-between bg-surface/90 px-4 pt-[calc(env(safe-area-inset-top,0px)+12px)] pb-2 backdrop-blur">
        <div>
          <h1 className="text-[22px] font-semibold tracking-tight text-t1">Sessions</h1>
          <div className="flex items-center gap-1 text-[12px] text-t3">
            {online ? (
              <>
                <ShieldCheck className="size-3.5 text-tone-green" strokeWidth={2.4} /> Mac verbunden · verschlüsselt
              </>
            ) : (
              <>
                <WifiOff className="size-3.5 text-tone-orange" strokeWidth={2.4} /> Verbindung weg — versuche es weiter
              </>
            )}
          </div>
        </div>
        <button
          type="button"
          onClick={() => setPicking(true)}
          aria-label="Neue Session"
          className="grid size-10 place-items-center rounded-full bg-active text-t1 active:bg-hair"
        >
          <Plus className="size-5" />
        </button>
      </header>

      <div className="flex-1 overflow-y-auto px-3 pb-8">
        {sessions.length === 0 && (
          <p className="mt-16 px-6 text-center text-[14px] text-t4">Keine offenen Sessions. Mit + öffnest du eine.</p>
        )}
        {urgent.length > 0 && (
          <Group name={`Braucht dich · ${urgent.length}`} accent>
            {urgent.map((s) => (
              <Row key={s.id} session={s} onOpen={onOpen} showGroup />
            ))}
          </Group>
        )}
        {groups.map((g) => (
          <Group key={g} name={g}>
            {sessions
              .filter((s) => s.group === g)
              .map((s) => (
                <Row key={s.id} session={s} onOpen={onOpen} />
              ))}
          </Group>
        ))}
      </div>

      <Sheet open={picking} onOpenChange={setPicking}>
        <SheetContent side="bottom" className="rounded-t-3xl border-hair bg-raised pb-[calc(env(safe-area-inset-bottom,0px)+16px)]">
          <SheetHeader>
            <SheetTitle>Neue Session</SheetTitle>
            <SheetDescription>Öffnet eine Session auf dem Mac, wie ⌘N.</SheetDescription>
          </SheetHeader>
          <div className="flex max-h-[50vh] flex-col gap-1 overflow-y-auto px-4">
            {folders.map((f) => (
              <button
                key={f}
                type="button"
                onClick={() => {
                  setPicking(false)
                  onNew(f)
                }}
                className="flex items-center gap-3 rounded-xl px-2 py-2.5 text-left active:bg-active"
              >
                <FolderGit2 className="size-5 shrink-0 text-t3" />
                <span className="min-w-0 truncate font-mono text-[14px] text-t1">{f}</span>
              </button>
            ))}
          </div>
        </SheetContent>
      </Sheet>
    </div>
  )
}

function Group({ name, accent, children }: { name: string; accent?: boolean; children: React.ReactNode }) {
  return (
    <section className="mt-4 flex flex-col gap-0.5">
      <h2 className={`px-2 pb-1 text-[11px] font-semibold tracking-[0.08em] uppercase ${accent ? 'text-tone-orange' : 'text-t5'}`}>
        {name}
      </h2>
      {children}
    </section>
  )
}

function Row({ session, onOpen, showGroup }: { session: Session; onOpen: (id: string) => void; showGroup?: boolean }) {
  return (
    <button
      type="button"
      onClick={() => onOpen(session.id)}
      className="flex min-h-[60px] w-full items-center gap-3 rounded-xl px-2 text-left active:bg-active"
    >
      <SessionTile agent={session.agent} attention={session.attention} isGit={session.isGit} />
      <div className="min-w-0 flex-1">
        <div className="truncate text-[15px] font-medium text-t1">{session.title}</div>
        <div className="truncate text-[12.5px] text-t4">
          {showGroup ? `${session.group} · ` : ''}
          {session.subtitle}
        </div>
      </div>
      {session.pr && <PRBadge number={session.pr.number} status={session.pr.status} />}
    </button>
  )
}
