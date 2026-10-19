import { Check, Search } from 'lucide-react'
import { useEffect, useMemo, useState } from 'react'
import { cn } from '@/lib/utils'
import { BottomSheet } from '@/components/BottomSheet'
import { Segmented, Switch } from '@/components/muxy'
import type { Repo } from '@/lib/protocol'
import type { NewSession as Spec } from '@/lib/useMuxy'
import { store, stored } from './TerminalView'

type AgentChoice = Spec['agent']

/** Like ⌘N on the Mac: an agent, what it should do, where, and whether on a branch of its own. */
export function NewSession({
  open,
  repos,
  recent,
  onClose,
  onStart,
}: {
  open: boolean
  repos: Repo[]
  recent: string[]
  onClose: () => void
  onStart: (spec: Spec) => void
}) {
  const [agent, setAgent] = useState<AgentChoice>(() => (stored('muxy.new.agent', 'claude') as AgentChoice) || 'claude')
  const [prompt, setPrompt] = useState('')
  const [directory, setDirectory] = useState(() => stored('muxy.new.dir', ''))
  const [worktree, setWorktree] = useState(() => stored('muxy.new.worktree', '1') === '1')
  const [query, setQuery] = useState('')

  // Muxy's repositories, else where sessions have been.
  const places: Repo[] = useMemo(() => {
    const list = repos.length ? repos : recent.map((path) => ({ path, name: path.split('/').at(-1) || path }))
    return list.length ? list : [{ path: '~', name: 'Home' }]
  }, [repos, recent])

  useEffect(() => {
    if (open && !places.some((p) => p.path === directory)) setDirectory(places[0].path)
  }, [open, places])

  useEffect(() => {
    if (!open) {
      setPrompt('')
      setQuery('')
    }
  }, [open])

  const shown = query ? places.filter((p) => `${p.name} ${p.path}`.toLowerCase().includes(query.toLowerCase())) : places
  const ready = !!directory && (agent === 'none' || prompt.trim().length > 0)

  function start() {
    if (!ready) return
    store('muxy.new.agent', agent)
    store('muxy.new.dir', directory)
    store('muxy.new.worktree', worktree ? '1' : '0')
    onStart({ directory, agent, prompt: prompt.trim(), worktree })
  }

  return (
    <BottomSheet
      open={open}
      onClose={onClose}
      title="Neue Session"
      action={
        <button type="button" disabled={!ready} onClick={start} className="text-[17px] font-semibold text-brand active:opacity-40 disabled:text-t5">
          Starten
        </button>
      }
    >
      <div className="px-4 pt-1">
        <Segmented
          value={agent}
          onChange={setAgent}
          options={[
            ['claude', 'Claude'],
            ['codex', 'Codex'],
            ['none', 'Terminal'],
          ]}
        />
      </div>

      {agent !== 'none' && (
        <>
          <Label>Aufgabe</Label>
          <div className="mx-4 rounded-[12px] bg-raised px-3.5 py-2.5">
            <textarea
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              rows={4}
              placeholder="Was soll passieren? Zum Beispiel: Behebe den Fehler beim Login und schreib einen Test dazu."
              className="block w-full resize-none bg-transparent text-[16px] leading-[1.4] text-t1 outline-none placeholder:text-t4"
            />
          </div>
        </>
      )}

      <Label>Repository</Label>
      {places.length > 6 && (
        <div className="mx-4 mb-2 flex h-9 items-center gap-2 rounded-[10px] bg-active px-2.5">
          <Search className="size-4 text-t4" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Suchen"
            autoCapitalize="off"
            autoCorrect="off"
            className="min-w-0 flex-1 bg-transparent text-[16px] text-t1 outline-none placeholder:text-t4"
          />
        </div>
      )}
      <div className="mx-4 overflow-hidden rounded-[12px] bg-raised">
        {shown.slice(0, 30).map((p, i) => (
          <button key={p.path} type="button" onClick={() => setDirectory(p.path)} className={cn('row-press flex min-h-[50px] w-full items-center gap-3 px-4 text-left')}>
            <div className={cn('flex min-w-0 flex-1 items-center gap-3 self-stretch py-2', i > 0 && 'border-t border-hair')}>
              <div className="min-w-0 flex-1">
                <div className="truncate text-[16px] text-t1">{p.name}</div>
                <div className="truncate text-[13px] text-t4">{p.path}</div>
              </div>
              {p.path === directory && <Check className="size-5 shrink-0 text-brand" strokeWidth={2.6} />}
            </div>
          </button>
        ))}
        {shown.length === 0 && <div className="px-4 py-3 text-[15px] text-t4">Nichts gefunden</div>}
      </div>

      <div className="mx-4 mt-6 flex min-h-[50px] items-center gap-3 rounded-[12px] bg-raised px-4">
        <span className="flex-1 text-[16px] text-t1">Eigener Worktree</span>
        <Switch label="Eigener Worktree" on={worktree} onChange={setWorktree} />
      </div>
      <p className="px-8 pt-1.5 text-[13px] leading-snug text-t4">
        {worktree ? 'Arbeitet auf einem neuen Branch, getrennt von allem anderen.' : 'Arbeitet direkt im Repository, auf dem aktuellen Branch.'}
      </p>
    </BottomSheet>
  )
}

function Label({ children }: { children: React.ReactNode }) {
  return <div className="px-8 pt-5 pb-1.5 text-[13px] font-medium tracking-[0.02em] text-t3 uppercase">{children}</div>
}
