// Example data for the prototype — shaped like what Muxy already knows
// about each session (Workspace / TerminalSession / RepoContext).

export type Agent = 'none' | 'idle' | 'working' | 'blocked' | 'failed'

export type PRStatus = 'none' | 'running' | 'fixing' | 'failed' | 'conflicts' | 'draft' | 'waiting' | 'ready'

export type ChatItem =
  | { kind: 'user'; text: string }
  | { kind: 'claude'; text: string }
  | { kind: 'tool'; tool: 'Read' | 'Bash' | 'Edit' | 'Grep'; target: string; output?: string[]; diff?: DiffLine[] }
  | { kind: 'permission'; command: string; why: string }
  | { kind: 'working'; label: string }
  | { kind: 'error'; type: string; text: string }

export type DiffLine = { sign: '+' | '-' | ' '; text: string }

export type Block = {
  id: string
  command: string
  exit: number | null
  ms: number
  output: string[]
  ask?: { question: string; choices: string[] }
  /** When the prompt was drawn — starship's right_format. */
  time?: string
}

export type Tab =
  | { id: string; kind: 'claude'; title: string; chat: ChatItem[] }
  | { id: string; kind: 'shell'; title: string; cwd: string; gitStatus: string; blocks: Block[] }

export type Session = {
  id: string
  group: string
  title: string
  subtitle: string
  isGit: boolean
  agent: Agent
  attention: boolean
  pr?: { number: number; status: PRStatus }
  tabs: Tab[]
}

export const MAC_NAME = 'MacBook Pro'

export const sessions: Session[] = [
  {
    id: 'badge',
    group: 'muxy',
    title: 'PR-Badge ehrlich machen',
    subtitle: 'fix/honest-pr-badge',
    isGit: true,
    agent: 'blocked',
    attention: true,
    pr: { number: 5, status: 'running' },
    tabs: [
      {
        id: 'badge-claude',
        kind: 'claude',
        title: 'Claude',
        chat: [
          { kind: 'user', text: 'Das PR-Badge sagt ready, obwohl #3793 ein Draft mit Konflikten ist. Grün bitte nur, wenn GitHub wirklich mergen würde.' },
          { kind: 'claude', text: 'Ich schaue mir an, wie Muxy die Checks auswertet.' },
          {
            kind: 'tool',
            tool: 'Read',
            target: 'Sources/muxy/Git.swift',
            output: ['108 Zeilen'],
          },
          {
            kind: 'tool',
            tool: 'Bash',
            target: 'gh pr view 3793 --json isDraft,mergeable,mergeStateStatus',
            output: ['{"isDraft":true,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING"}'],
          },
          { kind: 'claude', text: 'Gefunden: grün heißt bisher nur „CI fertig“. Draft, Konflikte und Branch-Protection fließen nicht ein. Ich ziehe sie mit in die Abfrage.' },
          {
            kind: 'tool',
            tool: 'Edit',
            target: 'Sources/muxy/Workspace.swift',
            diff: [
              { sign: ' ', text: 'var prStatus: PRStatus {' },
              { sign: '-', text: '    switch context.checks {' },
              { sign: '-', text: '    case .passed: .ready' },
              { sign: '+', text: '    if context.checks == .failed { return isBusy ? .fixing : .failed }' },
              { sign: '+', text: '    if context.mergeability == .conflicting { return .conflicts }' },
              { sign: '+', text: '    if context.isDraft { return .draft }' },
              { sign: '+', text: '    return context.mergeability == .clean ? .ready : .waiting' },
            ],
          },
          {
            kind: 'tool',
            tool: 'Bash',
            target: 'swift build',
            output: ['Compiling muxy Workspace.swift', 'Build complete! (2.34s)'],
          },
          { kind: 'claude', text: 'Build ist grün. Ich pushe den Branch, damit die CI läuft.' },
          { kind: 'permission', command: 'git push -u origin fix/honest-pr-badge', why: 'Bash · verändert ein Remote' },
        ],
      },
      {
        id: 'badge-shell',
        kind: 'shell',
        title: 'muxy',
        cwd: '~/muxy',
        gitStatus: '!3 ',
        blocks: [
          {
            id: 'b1',
            time: '11:20',
            command: 'git status --short',
            exit: 0,
            ms: 40,
            output: [' M Sources/muxy/Components.swift', ' M Sources/muxy/Git.swift', ' M Sources/muxy/Workspace.swift'],
          },
        ],
      },
    ],
  },
  {
    id: 'remote',
    group: 'muxy',
    title: 'Remote-Prototyp',
    subtitle: 'proto/remote-ui',
    isGit: true,
    agent: 'working',
    attention: false,
    tabs: [
      {
        id: 'remote-claude',
        kind: 'claude',
        title: 'Claude',
        chat: [
          { kind: 'user', text: 'Bau den Handy-Prototypen: Sidebar, Blöcke, Live-Modus, Claude-Chat. Im Muxy-Stil.' },
          { kind: 'claude', text: 'Ich nehme die Farben aus Theme.swift und dein Ghostty-Theme, damit es aussieht wie Muxy.' },
          { kind: 'tool', tool: 'Read', target: 'Sources/muxy/Theme.swift', output: ['194 Zeilen'] },
          { kind: 'tool', tool: 'Bash', target: 'pnpm add tailwindcss @tailwindcss/vite lucide-react', output: ['Done in 4.1s'] },
          { kind: 'working', label: 'Schreibt src/screens/ShellView.tsx' },
        ],
      },
      {
        id: 'remote-dev',
        kind: 'shell',
        title: 'pnpm dev',
        cwd: '~/muxy/Prototypes/remote',
        gitStatus: '?1 ',
        blocks: [
          {
            id: 'd1',
            time: '11:41',
            command: 'pnpm dev',
            exit: null,
            ms: 0,
            output: ['  VITE v8.3.0  ready in 212 ms', '', '  ➜  Local:   http://localhost:5173/', '  ➜  press h + enter to show help', '11:42:07 [vite] (client) hmr update /src/App.tsx'],
          },
        ],
      },
    ],
  },
  {
    id: 'errors',
    group: 'project-phoenix',
    title: 'Fehlercodes umbenennen',
    subtitle: 'refactor/error-codes',
    isGit: true,
    agent: 'idle',
    attention: true,
    pr: { number: 3793, status: 'conflicts' },
    tabs: [
      {
        id: 'errors-claude',
        kind: 'claude',
        title: 'Claude',
        chat: [
          { kind: 'user', text: 'Benenn alle Fehlercodes auf bereich.fehlername um (#2506).' },
          { kind: 'tool', tool: 'Grep', target: 'ErrCode[A-Z]\\w+', output: ['214 Treffer in 61 Dateien'] },
          { kind: 'tool', tool: 'Bash', target: 'go test ./backend/...', output: ['ok  	phoenix/backend/api	3.112s', 'ok  	phoenix/backend/auth	1.840s'] },
          { kind: 'claude', text: 'Fertig: 214 Codes umbenannt, Tests grün. Achtung, der PR hat inzwischen Konflikte mit development. Soll ich rebasen?' },
        ],
      },
    ],
  },
  {
    id: 'avatars',
    group: 'project-phoenix',
    title: 'Profilbilder Seed',
    subtitle: 'feat/seed-avatars',
    isGit: true,
    agent: 'failed',
    attention: true,
    pr: { number: 3783, status: 'draft' },
    tabs: [
      {
        id: 'avatars-claude',
        kind: 'claude',
        title: 'Claude',
        chat: [
          { kind: 'user', text: 'Generier Profilbilder aus dem moto-Logo für die Marketing-Schule.' },
          { kind: 'tool', tool: 'Bash', target: 'go run ./cmd/seed --school marketing', output: ['seeded 48 users'] },
          { kind: 'error', type: 'rate_limit', text: 'Die Runde ist an einem API-Fehler gestorben (rate_limit, 14:32).' },
        ],
      },
    ],
  },
  {
    id: 'calperiods',
    group: 'project-phoenix',
    title: 'calperiods',
    subtitle: 'feat/calendar-periods',
    isGit: true,
    agent: 'none',
    attention: false,
    pr: { number: 3801, status: 'ready' },
    tabs: [
      {
        id: 'cal-shell',
        kind: 'shell',
        title: 'calperiods',
        cwd: '~/project-phoenix-calperiods',
        gitStatus: '',
        blocks: [
          { id: 'c1', time: '14:51', command: 'git pull --rebase', exit: 0, ms: 1200, output: ['Already up to date.'] },
          {
            id: 'c2',
            time: '14:52',
            command: 'go test ./backend/...',
            exit: 1,
            ms: 4800,
            output: [
              'ok  	phoenix/backend/api	3.112s',
              'ok  	phoenix/backend/auth	1.840s',
              '--- FAIL: TestPeriodOverlap (0.00s)',
              '    periods_test.go:88: expected 2 periods, got 3',
              '    periods_test.go:91: period[2].End = 2026-10-31, want 2026-10-30',
              'FAIL	phoenix/backend/calendar	0.412s',
              'ok  	phoenix/backend/seed	0.993s',
              'FAIL',
            ],
          },
          { id: 'c3', time: '14:58', command: 'pnpm lint', exit: 0, ms: 6100, output: ['✓ 0 problems'] },
        ],
      },
    ],
  },
  {
    id: 'home',
    group: 'Terminal',
    title: '~',
    subtitle: 'Home',
    isGit: false,
    agent: 'none',
    attention: false,
    tabs: [{ id: 'home-shell', kind: 'shell', title: '~', cwd: '~', gitStatus: '', blocks: [] }],
  },
]

/** What the input line suggests — all of it known on the Mac. */
export const suggestions = {
  history: ['go test ./backend/calendar/...', 'git status', 'htop', 'git push'],
  scripts: ['pnpm test', 'pnpm lint', 'make reset-db'],
  branches: ['development', 'feat/calendar-periods', 'fix/period-overlap'],
  folders: ['backend', 'frontend', 'scripts', 'docs', '.github'],
}

export const recentFolders = [
  { path: '~/project-phoenix-dev', repo: 'project-phoenix' },
  { path: '~/muxy', repo: 'muxy' },
  { path: '~/project-phoenix-onboarding', repo: 'project-phoenix' },
  { path: '~/TTagebuch', repo: 'TTagebuch' },
]

/** Fake replies for commands typed in the prototype. */
export function runFake(command: string): Omit<Block, 'id' | 'command'> {
  const c = command.trim()
  if (c === 'git status') return { exit: 0, ms: 30, output: ['On branch feat/calendar-periods', 'nothing to commit, working tree clean'] }
  if (c.startsWith('go test')) return { exit: 0, ms: 2100, output: ['ok  	phoenix/backend/calendar	0.398s'] }
  if (c === 'pnpm test') return { exit: 0, ms: 8200, output: [' ✓ 412 tests passed', ' Duration  8.12s'] }
  if (c === 'pnpm lint') return { exit: 0, ms: 6000, output: ['✓ 0 problems'] }
  if (c === 'make reset-db')
    return { exit: null, ms: 0, output: ['This drops the local database phoenix_dev.'], ask: { question: 'Continue? [y/N]', choices: ['y', 'N'] } }
  if (c === 'git push') return { exit: 1, ms: 900, output: ['fatal: The current branch has no upstream branch.', 'To push the current branch and set the remote as upstream, use', '', '    git push --set-upstream origin feat/calendar-periods'] }
  if (c.startsWith('cd ')) return { exit: 0, ms: 0, output: [] }
  if (c.startsWith('git checkout ')) return { exit: 0, ms: 90, output: [`Switched to branch '${c.slice(13)}'`] }
  if (c === 'ls') return { exit: 0, ms: 5, output: ['backend  docs  frontend  scripts  Makefile  README.md'] }
  return { exit: 127, ms: 4, output: [`zsh: command not found: ${c.split(' ')[0]}`] }
}
