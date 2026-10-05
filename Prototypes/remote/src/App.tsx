import { useState } from 'react'
import { sessions as initial, runFake, type ChatItem, type Session, type Tab } from '@/data'
import { Lock } from '@/screens/Lock'
import { Sessions } from '@/screens/Sessions'
import { SessionScreen, type SessionActions } from '@/screens/SessionScreen'

type Screen = { name: 'lock' } | { name: 'list' } | { name: 'session'; id: string }

let seq = 0
const nextId = () => `x${++seq}`
const clock = () => new Date().toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' })

export default function App() {
  const [screen, setScreen] = useState<Screen>({ name: 'lock' })
  const [sessions, setSessions] = useState<Session[]>(initial)

  function patchSession(id: string, fn: (s: Session) => Session) {
    setSessions((all) => all.map((s) => (s.id === id ? fn(s) : s)))
  }
  function patchTab(sessionId: string, tabId: string, fn: (t: Tab) => Tab) {
    patchSession(sessionId, (s) => ({ ...s, tabs: s.tabs.map((t) => (t.id === tabId ? fn(t) : t)) }))
  }
  function patchChat(sessionId: string, tabId: string, fn: (chat: ChatItem[]) => ChatItem[]) {
    patchTab(sessionId, tabId, (t) => (t.kind === 'claude' ? { ...t, chat: fn(t.chat) } : t))
  }

  /** Coming to the front: like Muxy's markSeen. */
  function open(id: string) {
    patchSession(id, (s) => ({ ...s, attention: false }))
    setScreen({ name: 'session', id })
  }

  const actions: SessionActions = {
    permission(sid, tid, choice) {
      if (choice === 'no') {
        patchChat(sid, tid, (c) => [
          ...c.filter((i) => i.kind !== 'permission'),
          { kind: 'claude', text: 'Okay, ich pushe nicht. Was soll ich stattdessen tun?' },
        ])
        patchSession(sid, (s) => ({ ...s, agent: 'idle' }))
        return
      }
      patchChat(sid, tid, (c) => [
        ...c.filter((i) => i.kind !== 'permission'),
        { kind: 'tool', tool: 'Bash', target: 'git push -u origin fix/honest-pr-badge', output: ['branch fix/honest-pr-badge set up to track origin'] },
        { kind: 'working', label: 'Öffnet den PR' },
      ])
      patchSession(sid, (s) => ({ ...s, agent: 'working' }))
      setTimeout(() => {
        patchChat(sid, tid, (c) => [
          ...c.filter((i) => i.kind !== 'working'),
          { kind: 'tool', tool: 'Bash', target: 'gh pr create --fill', output: ['https://github.com/theitger/muxy/pull/5'] },
          { kind: 'claude', text: 'PR #5 ist offen, die Checks laufen. Ich melde mich, wenn sie durch sind.' },
        ])
        patchSession(sid, (s) => ({ ...s, agent: 'idle' }))
      }, 1600)
    },

    send(sid, tid, text) {
      patchChat(sid, tid, (c) => [
        ...c.filter((i) => i.kind !== 'error'),
        { kind: 'user', text },
        { kind: 'working', label: 'Denkt nach' },
      ])
      patchSession(sid, (s) => ({ ...s, agent: 'working' }))
      setTimeout(() => {
        const reply: ChatItem[] =
          text === 'weiter'
            ? [
                { kind: 'tool', tool: 'Bash', target: 'go run ./cmd/seed --school marketing --avatars', output: ['generated 48 avatars'] },
                { kind: 'claude', text: 'Weiter ging es: 48 Profilbilder erzeugt und im Seed hinterlegt.' },
              ]
            : text.startsWith('Ja, rebase')
              ? [
                  { kind: 'tool', tool: 'Bash', target: 'git rebase origin/development', output: ['Successfully rebased and updated refs/heads/refactor/error-codes.'] },
                  { kind: 'claude', text: 'Rebase sauber durch, keine Konflikte mehr. Soll ich force-pushen?' },
                ]
              : [{ kind: 'claude', text: `Mach ich: „${text}“.` }]
        patchChat(sid, tid, (c) => [...c.filter((i) => i.kind !== 'working'), ...reply])
        patchSession(sid, (s) => ({
          ...s,
          agent: 'idle',
          pr: s.pr && text.startsWith('Ja, rebase') ? { ...s.pr, status: 'running' } : s.pr,
        }))
      }, 1400)
    },

    run(sid, tid, command) {
      const id = nextId()
      if (command.startsWith('__live:')) {
        patchTab(sid, tid, (t) =>
          t.kind === 'shell' ? { ...t, blocks: [...t.blocks, { id, time: clock(), command: command.slice(7), exit: 0, ms: 9300, output: [] }] } : t,
        )
        return
      }
      const result = runFake(command)
      patchTab(sid, tid, (t) =>
        t.kind === 'shell' ? { ...t, blocks: [...t.blocks, { id, time: clock(), command, exit: null, ms: 0, output: [] }] } : t,
      )
      setTimeout(
        () =>
          patchTab(sid, tid, (t) => {
            if (t.kind !== 'shell') return t
            const cwd = command.startsWith('cd ') ? `${t.cwd}/${command.slice(3)}` : t.cwd
            return { ...t, cwd, blocks: t.blocks.map((b) => (b.id === id ? { ...b, ...result } : b)) }
          }),
        Math.min(Math.max(result.ms, 250), 1500),
      )
    },

    answer(sid, tid, blockId, choice) {
      patchTab(sid, tid, (t) =>
        t.kind === 'shell'
          ? {
              ...t,
              blocks: t.blocks.map((b) =>
                b.id === blockId
                  ? choice === 'y'
                    ? { ...b, exit: 0, ms: 3400, ask: undefined, output: [...b.output, 'Continue? [y/N] y', 'Dropped phoenix_dev.', 'Applied 42 migrations.'] }
                    : { ...b, exit: 1, ms: 2100, ask: undefined, output: [...b.output, 'Continue? [y/N] N', 'Aborted.'] }
                  : b,
              ),
            }
          : t,
      )
    },
  }

  const urgent = sessions.filter((s) => s.agent === 'blocked' || s.agent === 'failed' || s.attention)

  return (
    <div className="mx-auto h-full max-w-[480px] overflow-hidden">
      {screen.name === 'lock' && <Lock onUnlock={(target) => (target ? open(target) : setScreen({ name: 'list' }))} />}
      {screen.name === 'list' && (
        <Sessions
          sessions={sessions}
          onOpen={open}
          onNew={(path) => {
            const id = nextId()
            const name = path.split('/').pop() ?? path
            setSessions((all) => [
              ...all,
              {
                id,
                group: path === '~/muxy' ? 'muxy' : name.startsWith('project-phoenix') ? 'project-phoenix' : name,
                title: name.replace(/^project-phoenix-/, ''),
                subtitle: 'development',
                isGit: true,
                agent: 'none',
                attention: false,
                tabs: [{ id: `${id}-t`, kind: 'shell', title: name, cwd: path, gitStatus: '', blocks: [] }],
              },
            ])
            setScreen({ name: 'session', id })
          }}
        />
      )}
      {screen.name === 'session' &&
        (() => {
          const s = sessions.find((x) => x.id === screen.id)
          if (!s) return null
          return (
            <SessionScreen
              key={s.id}
              session={s}
              urgentElsewhere={urgent.filter((u) => u.id !== s.id).length}
              onBack={() => setScreen({ name: 'list' })}
              actions={actions}
            />
          )
        })()}
    </div>
  )
}
