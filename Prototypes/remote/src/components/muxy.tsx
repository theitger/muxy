import {
  Bell,
  Check,
  CircleDashed,
  Folder,
  GitBranch,
  GitMerge,
  Hand,
  Hourglass,
  Pencil,
  Sparkle,
  TextCursor,
  TriangleAlert,
  Wrench,
  X,
  type LucideIcon,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import type { Agent, PRStatus } from '@/data'

type Tone = 'blue' | 'green' | 'yellow' | 'orange' | 'red' | 'neutral'

const toneClass: Record<Tone, string> = {
  blue: 'bg-tone-blue-soft text-tone-blue',
  green: 'bg-tone-green-soft text-tone-green',
  yellow: 'bg-tone-yellow-soft text-tone-yellow',
  orange: 'bg-tone-orange-soft text-tone-orange',
  red: 'bg-tone-red-soft text-tone-red',
  neutral: 'bg-tone-neutral-soft text-t3',
}

/** Muxy's SessionTile: what a session is and whether it wants you. */
export function SessionTile({
  agent,
  attention,
  isGit,
  size = 36,
}: {
  agent: Agent
  attention: boolean
  isGit: boolean
  size?: number
}) {
  const [Icon, tone]: [LucideIcon, Tone] =
    agent === 'blocked'
      ? [Hand, 'orange']
      : agent === 'failed'
        ? [TriangleAlert, 'red']
        : agent === 'working'
          ? [Sparkle, 'blue']
          : agent === 'idle'
            ? attention
              ? [Check, 'green']
              : [TextCursor, 'neutral']
            : attention
              ? [Bell, 'orange']
              : [isGit ? GitBranch : Folder, 'neutral']
  return (
    <div
      className={cn('grid shrink-0 place-items-center', toneClass[tone])}
      style={{ width: size, height: size, borderRadius: size * 0.3 }}
    >
      <Icon
        className={cn(agent === 'working' && 'pulse-soft')}
        style={{ width: size * 0.44, height: size * 0.44 }}
        strokeWidth={2.4}
        fill={agent === 'working' ? 'currentColor' : 'none'}
      />
    </div>
  )
}

const prLook: Record<PRStatus, [LucideIcon | null, Tone, string]> = {
  none: [null, 'neutral', 'Keine Checks'],
  running: [CircleDashed, 'blue', 'Checks laufen'],
  fixing: [Wrench, 'yellow', 'Checks rot — wird gefixt'],
  failed: [X, 'red', 'Checks fehlgeschlagen'],
  conflicts: [GitMerge, 'red', 'Merge-Konflikte'],
  draft: [Pencil, 'neutral', 'Entwurf'],
  waiting: [Hourglass, 'neutral', 'Checks grün — Merge blockiert'],
  ready: [Check, 'green', 'Bereit zum Mergen'],
}

/** Muxy's PRBadge: the PR number, tinted by how close it is to mergeable. */
export function PRBadge({ number, status }: { number: number; status: PRStatus }) {
  const [Icon, tone, help] = prLook[status]
  return (
    <span
      title={help}
      aria-label={`PR #${number}: ${help}`}
      className={cn(
        'inline-flex h-[21px] shrink-0 items-center gap-1 rounded-full px-2 text-[12px] font-medium tabular-nums',
        toneClass[tone],
      )}
    >
      {Icon && <Icon className="size-[10px]" strokeWidth={3} />}#{number}
    </span>
  )
}

export function prHelp(status: PRStatus) {
  return prLook[status][2]
}

/** One key on the key bar — big enough for a thumb. */
export function Key({
  children,
  onPress,
  wide,
  active,
  label,
}: {
  children: React.ReactNode
  onPress: () => void
  wide?: boolean
  active?: boolean
  label?: string
}) {
  return (
    <button
      type="button"
      aria-label={label}
      onClick={onPress}
      className={cn(
        'grid h-9 shrink-0 place-items-center rounded-lg border border-hair px-2.5 font-mono text-[13px] text-t2 transition-colors active:bg-active',
        wide ? 'min-w-14' : 'min-w-10',
        active ? 'bg-t1 text-bg' : 'bg-raised',
      )}
    >
      {children}
    </button>
  )
}
