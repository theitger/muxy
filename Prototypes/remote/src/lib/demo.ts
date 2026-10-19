import { useCallback, useEffect, useState } from 'react'
import { t } from './i18n'
import type { Muxy, NewSession } from './useMuxy'
import type { ChatItem, Issue, Key, Screen, Session, StepKind } from './protocol'

/** Development only (`pnpm dev`, then open /#demo): made-up sessions to design against. */
export const isDemo = import.meta.env.DEV && typeof location !== 'undefined' && location.hash.includes('demo')

const now = Date.now() / 1000

const sessions: Session[] = [
  {
    id: 'w1',
    group: 'project-phoenix',
    title: 'Offboarding Löschfrist',
    subtitle: 'feat/4047-loeschfrist',
    directory: '~/project-phoenix/.worktrees/4047',
    isGit: true,
    agent: 'blocked',
    agentKind: 'claude',
    attention: true,
    lines: ['Bash command', '  go test ./backend/services/...', '  Run the service tests'],
    pr: { number: 4288, status: 'running' },
    next: { kind: 'answer', title: 'Answer the agent' },
    stage: 'working',
    tabs: [
      {
        id: 't1',
        kind: 'agent',
        agentKind: 'claude',
        title: 'Claude',
        agent: 'blocked',
        attention: true,
        since: now - 140,
        choices: [
          { number: 1, label: 'Yes', selected: true },
          { number: 2, label: "Yes, and don't ask again for go test commands", selected: false },
          { number: 3, label: 'No, and tell Claude what to do differently', selected: false },
        ],
      },
      { id: 't1b', kind: 'shell', title: 'fish', agent: 'none', attention: false },
    ],
  },
  {
    id: 'w2',
    group: 'muxy',
    title: 'Phone app feels native',
    subtitle: 'feat/phone',
    directory: '~/muxy/.worktrees/phone',
    isGit: true,
    agent: 'working',
    agentKind: 'codex',
    attention: false,
    activity: 'Running swift build',
    lines: ['• Edited Sources/muxy/Remote/Transcript.swift (+84 -12)', '• Ran swift build'],
    tabs: [{ id: 't2', kind: 'agent', agentKind: 'codex', title: 'Codex', agent: 'working', attention: false }],
  },
  {
    id: 'w3',
    group: 'muxy',
    title: 'Inbox replies',
    subtitle: 'feat/inbox',
    directory: '~/muxy/.worktrees/inbox',
    isGit: true,
    agent: 'idle',
    agentKind: 'claude',
    attention: false,
    lines: ['All 93 tests pass. The inbox now answers from notifications too.'],
    pr: { number: 12, status: 'ready' },
    agentTab: 't3',
    next: { kind: 'land', title: 'Land' },
    stage: 'ready',
    proof: 'passed',
    quorum: { summary: 'quorum: clean', running: false, clean: true },
    tabs: [{ id: 't3', kind: 'agent', agentKind: 'claude', title: 'Claude', agent: 'idle', attention: false, since: now - 900 }],
  },
  {
    id: 'w6',
    group: 'project-phoenix',
    title: '#3400 Personalaustritt behält Kontolink',
    subtitle: '3400-personalaustritt',
    directory: '~/project-phoenix/.worktrees/3400',
    isGit: true,
    agent: 'idle',
    agentKind: 'codex',
    attention: false,
    agentTab: 't6',
    next: { kind: 'openPR', title: 'Open a pull request' },
    stage: 'working',
    proof: 'failed',
    collisions: ['#4045 Löschfrist'],
    tabs: [{ id: 't6', kind: 'agent', agentKind: 'codex', title: 'Codex', agent: 'idle', attention: false }],
  },
  {
    id: 'w7',
    group: 'project-phoenix',
    title: '#4045 Löschfrist Schulinhalte',
    subtitle: 'feat/4045-retention',
    directory: '~/project-phoenix/.worktrees/4045',
    isGit: true,
    agent: 'idle',
    agentKind: 'claude',
    attention: false,
    pr: { number: 4378, status: 'running' },
    agentTab: 't7',
    next: { kind: 'review', title: 'Review with quorum' },
    stage: 'review',
    tabs: [{ id: 't7', kind: 'agent', agentKind: 'claude', title: 'Claude', agent: 'idle', attention: false }],
  },
  {
    id: 'w4',
    group: 'project-phoenix',
    title: 'Migrations check',
    subtitle: 'fix/migrations',
    directory: '~/project-phoenix/.worktrees/mig',
    isGit: true,
    agent: 'failed',
    agentKind: 'codex',
    attention: true,
    lines: ['stream error: overloaded'],
    tabs: [{ id: 't4', kind: 'agent', agentKind: 'codex', title: 'Codex', agent: 'failed', attention: true, since: now - 3000 }],
  },
  {
    id: 'w5',
    group: 'dotfiles',
    title: 'dotfiles',
    subtitle: 'main',
    directory: '~/dotfiles',
    isGit: true,
    agent: 'none',
    attention: false,
    tabs: [{ id: 't5', kind: 'shell', title: 'fish', agent: 'none', attention: false }],
  },
]

const issues: Issue[] = [
  { repo: 'moto-nrw/project-phoenix', number: 3949, title: 'Spec: Löschfristen für alle Datenarten durchsetzen (#3839, #2788)', url: 'https://github.com/moto-nrw/project-phoenix/issues/3949', labels: ['ready-for-agent'], local: true, created: now - 6 * 86400 },
  { repo: 'moto-nrw/project-phoenix', number: 3839, title: 'Löschfristen für weitere Tabellen ergänzen (Ergänzung zu #2788)', url: '', labels: ['priority: high'], local: true, created: now - 16 * 86400 },
  { repo: 'moto-nrw/website', number: 151, title: 'Preise auf der Startseite aktualisieren', url: '', labels: [], local: false, created: now - 20 * 86400 },
  { repo: 'moto-nrw/project-phoenix', number: 3472, title: 'Öffentliche Demo: Abnahme vor der Messe', url: '', labels: ['feature', 'priority: high'], local: true, created: now - 28 * 86400 },
  { repo: 'moto-nrw/PyrePortal', number: 439, title: 'Terminal zeigt eindeutig, ob Raum oder Aktivität voll ist', url: '', labels: ['ready-for-agent'], local: true, created: now - 40 * 86400 },
]

const claudeScreen = `⏺ I'll run the service tests to make sure the cleanup works.

⏺ Bash(go test ./backend/services/...)
  ⎿  Running…

────────────────────────────────────────────────────────────
 Bash command

   go test ./backend/services/...
   Run the service tests

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for go test commands in ~/project-phoenix
   3. No, and tell Claude what to do differently (esc)
`

const shellScreen = `~/dotfiles on  main
❯ git status
On branch main
Your branch is up to date with 'origin/main'.

nothing to commit, working tree clean

~/dotfiles on  main
❯ `

const chat: ChatItem[] = [
  { kind: 'user', text: 'Ausgetretene Mitarbeiter sollen nach Ablauf der Frist auch aus den historischen Stundenplänen verschwinden.' },
  {
    kind: 'agent',
    text: 'Ich schaue mir zuerst an, wie die Löschfrist heute umgesetzt ist.\n\nDie Bereinigung läuft in `retention.go`, aber sie fasst nur **aktuelle** Zuordnungen an:\n\n- `schedule.instance_staff` bleibt stehen\n- das Audit-Log zählt nur Personen\n\nIch ergänze das und schreibe einen Test.',
  },
  { kind: 'tool', id: 'a', tool: 'Read', target: 'backend/services/retention.go', done: true, output: ['package services', '…'] },
  {
    kind: 'tool',
    id: 'b',
    tool: 'Edit',
    target: 'backend/services/retention.go',
    done: true,
    diff: [
      { sign: '-', text: '\treturn s.deletePerson(ctx, id)' },
      { sign: '+', text: '\tif err := s.deleteInstanceStaff(ctx, id); err != nil {' },
      { sign: '+', text: '\t\treturn err' },
      { sign: '+', text: '\t}' },
      { sign: '+', text: '\treturn s.deletePerson(ctx, id)' },
    ],
  },
  { kind: 'tool', id: 'c', tool: 'Bash', target: 'go test ./backend/services/...', done: false },
]

export function useDemo(): Muxy {
  const [opened, setOpened] = useState<Muxy['opened']>(null)
  const [list, setList] = useState(sessions)
  useEffect(() => {
    const id = setInterval(() => {
      setList((l) => l.map((s) => (s.id === 'w2' ? { ...s, activity: s.activity === 'Running swift build' ? 'Reading Transcript.swift' : 'Running swift build' } : s)))
    }, 2500)
    return () => clearInterval(id)
  }, [])
  const screens: Record<string, Screen> = {
    t1: { text: claudeScreen, columns: 100, rows: 30 },
    t1b: { text: shellScreen, columns: 100, rows: 30 },
    t5: { text: shellScreen, columns: 100, rows: 30 },
    t2: { text: '• Working (12s • esc to interrupt)', columns: 100, rows: 30 },
    t3: { text: 'All 93 tests pass.', columns: 100, rows: 30 },
    t4: { text: 'stream error: overloaded', columns: 100, rows: 30 },
  }
  const resolve = useCallback((tab: string) => {
    setList((l) =>
      l.map((s) =>
        s.tabs.some((t) => t.id === tab)
          ? { ...s, agent: 'working', attention: false, activity: 'Running go test', tabs: s.tabs.map((t) => (t.id === tab ? { ...t, agent: 'working', attention: false, choices: undefined } : t)) }
          : s,
      ),
    )
  }, [])
  return {
    paired: true,
    state: 'open',
    sessions: list,
    recent: ['~/muxy', '~/project-phoenix'],
    repos: [
      { path: '~/muxy', name: 'muxy' },
      { path: '~/project-phoenix', name: 'project-phoenix' },
      { path: '~/dotfiles', name: 'dotfiles' },
    ],
    history: ['git status', 'swift build', 'pnpm dev --host'],
    screens,
    chats: { t1: chat, t3: chat.slice(0, 2), t2: chat.slice(0, 2), t4: [] },
    opened,
    watch: useCallback(() => {}, []),
    type: useCallback((tab: string) => resolve(tab), [resolve]),
    key: useCallback((_tab: string, _k: Key | string) => {}, []),
    choose: useCallback((tab: string) => resolve(tab), [resolve]),
    loadRepos: useCallback(() => {}, []),
    issues,
    account: { login: 'theitger', name: 'trizzy', avatar: 'https://avatars.githubusercontent.com/u/169249101?v=4' },
    step: useCallback((session: string, _kind: StepKind) => {
      setList((l) => l.map((s) => (s.id === session ? { ...s, next: { kind: 'wait', title: t('Working') }, agent: 'working', activity: 'Opening the pull request' } : s)))
    }, []),
    startIssue: useCallback(() => {}, []),
    start: useCallback((spec: NewSession) => {
      const id = `n${Date.now()}`
      setList((l) => [
        ...l,
        {
          id,
          group: spec.directory.split('/').at(-1) ?? t('new'),
          title: spec.prompt.slice(0, 40) || t('New Session'),
          subtitle: spec.worktree ? t('new worktree') : spec.directory,
          directory: spec.directory,
          isGit: true,
          agent: spec.agent === 'none' ? 'none' : 'working',
          agentKind: spec.agent === 'none' ? undefined : spec.agent,
          attention: false,
          activity: 'Starting',
          tabs: [{ id: `${id}t`, kind: spec.agent === 'none' ? 'shell' : 'agent', agentKind: spec.agent === 'none' ? undefined : spec.agent, title: spec.agent, agent: 'working', attention: false }],
        },
      ])
      setTimeout(() => setOpened({ session: id, at: Date.now() }), 400)
    }, []),
  }
}
