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
import { useEffect, useState } from 'react'
import { cn } from '@/lib/utils'
import { agentName, type Agent, type PRStatus, type Session } from '@/lib/protocol'

export type Tone = 'blue' | 'green' | 'yellow' | 'orange' | 'red' | 'neutral'

export const toneClass: Record<Tone, string> = {
  blue: 'bg-tone-blue-soft text-tone-blue',
  green: 'bg-tone-green-soft text-tone-green',
  yellow: 'bg-tone-yellow-soft text-tone-yellow',
  orange: 'bg-tone-orange-soft text-tone-orange',
  red: 'bg-tone-red-soft text-tone-red',
  neutral: 'bg-tone-neutral-soft text-t3',
}

export const toneText: Record<Tone, string> = {
  blue: 'text-tone-blue',
  green: 'text-tone-green',
  yellow: 'text-tone-yellow',
  orange: 'text-tone-orange',
  red: 'text-tone-red',
  neutral: 'text-t3',
}

export const wantsYou = (s: Session) => s.agent === 'blocked' || s.agent === 'failed' || s.attention

/** How urgent: blocked first, then failed, then news. */
export const urgency = (s: Session) => (s.agent === 'blocked' ? 0 : s.agent === 'failed' ? 1 : 2)

/** One line on what a session is up to, and its tone. */
export function status(s: Session): { text: string; tone: Tone; live?: boolean } {
  const who = agentName(s.agentKind)
  switch (s.agent) {
    case 'blocked':
      return { text: `${who} wartet auf deine Antwort`, tone: 'orange' }
    case 'failed':
      return { text: `${who} ist an einem Fehler hängen geblieben`, tone: 'red' }
    case 'working':
      return { text: s.activity ?? `${who} arbeitet`, tone: 'blue', live: true }
    case 'idle':
      return s.attention ? { text: `${who} ist fertig`, tone: 'green' } : { text: `${who} ist bereit`, tone: 'neutral' }
    default:
      return s.attention ? { text: s.notice ?? 'Neue Ausgabe', tone: 'orange' } : { text: s.subtitle || s.directory, tone: 'neutral' }
  }
}

/** Muxy's SessionTile: what a session is and whether it wants you. */
export function SessionTile({ agent, attention, isGit, size = 36 }: { agent: Agent; attention: boolean; isGit: boolean; size?: number }) {
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
      className={cn('grid shrink-0 place-items-center transition-colors duration-300', toneClass[tone])}
      style={{ width: size, height: size, borderRadius: size * 0.28 }}
    >
      <Icon
        className={cn(agent === 'working' && 'pulse-soft')}
        style={{ width: size * 0.46, height: size * 0.46 }}
        strokeWidth={2.3}
        fill={agent === 'working' ? 'currentColor' : 'none'}
      />
    </div>
  )
}

const prLook: Record<PRStatus, [LucideIcon | null, Tone, string]> = {
  none: [null, 'neutral', 'Keine Checks'],
  running: [CircleDashed, 'blue', 'Checks laufen'],
  fixing: [Wrench, 'yellow', 'Checks rot, wird gefixt'],
  failed: [X, 'red', 'Checks fehlgeschlagen'],
  conflicts: [GitMerge, 'red', 'Merge-Konflikte'],
  draft: [Pencil, 'neutral', 'Entwurf'],
  waiting: [Hourglass, 'neutral', 'Checks grün, Merge blockiert'],
  ready: [Check, 'green', 'Bereit zum Mergen'],
  merged: [GitMerge, 'green', 'Gemergt'],
  closed: [X, 'neutral', 'Geschlossen, nicht gemergt'],
}

/** Muxy's PRBadge: the PR number, tinted by how close it is to mergeable. */
export function PRBadge({ number, status }: { number: number; status: PRStatus }) {
  const [Icon, tone, help] = prLook[status] ?? prLook.none
  return (
    <span
      title={help}
      aria-label={`PR #${number}: ${help}`}
      className={cn('inline-flex h-[22px] shrink-0 items-center gap-1 rounded-full px-2 text-[12.5px] font-medium tabular-nums', toneClass[tone])}
    >
      {Icon && <Icon className="size-[11px]" strokeWidth={3} />}#{number}
    </span>
  )
}

export function prHelp(status: PRStatus) {
  return prLook[status][2]
}

/** "gerade", "vor 4 Min.", "vor 2 Std." — refreshed every half minute. */
export function Ago({ since }: { since?: number }) {
  const [, tick] = useState(0)
  useEffect(() => {
    const id = setInterval(() => tick((n) => n + 1), 30_000)
    return () => clearInterval(id)
  }, [])
  if (!since) return null
  const s = Math.max(0, Date.now() / 1000 - since)
  const text = s < 60 ? 'gerade' : s < 3600 ? `vor ${Math.floor(s / 60)} Min.` : s < 86400 ? `vor ${Math.floor(s / 3600)} Std.` : `vor ${Math.floor(s / 86400)} T.`
  return <span className="tabular-nums">{text}</span>
}

/** An iOS switch. */
export function Switch({ on, onChange, label }: { on: boolean; onChange: (on: boolean) => void; label: string }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      onClick={() => onChange(!on)}
      className={cn('relative h-[31px] w-[51px] shrink-0 rounded-full transition-colors duration-200', on ? 'bg-tone-green-strong' : 'bg-t5/35')}
    >
      <span
        className="absolute top-[2px] left-[2px] size-[27px] rounded-full bg-white shadow-[0_3px_8px_rgb(0_0_0/0.15),0_1px_1px_rgb(0_0_0/0.16)] transition-transform duration-200 ease-[cubic-bezier(0.32,0.72,0,1)]"
        style={{ transform: on ? 'translateX(20px)' : 'none' }}
      />
    </button>
  )
}

/** An iOS segmented control; the thumb slides. */
export function Segmented<T extends string>({ value, onChange, options, className }: { value: T; onChange: (v: T) => void; options: [T, string][]; className?: string }) {
  const index = Math.max(0, options.findIndex(([v]) => v === value))
  return (
    <div className={cn('relative grid rounded-[9px] bg-active p-[2px]', className)} style={{ gridTemplateColumns: `repeat(${options.length}, 1fr)` }} role="tablist">
      <span
        className="absolute top-[2px] bottom-[2px] left-[2px] rounded-[7px] bg-raised shadow-[0_3px_8px_rgb(0_0_0/0.12),0_3px_1px_rgb(0_0_0/0.04)] transition-transform duration-300 ease-[cubic-bezier(0.32,0.72,0,1)] dark:bg-[#636366]"
        style={{ width: `calc((100% - 4px) / ${options.length})`, transform: `translateX(${index * 100}%)` }}
      />
      {options.map(([v, label]) => (
        <button
          key={v}
          type="button"
          role="tab"
          aria-selected={value === v}
          onClick={() => onChange(v)}
          className={cn('relative z-10 h-[28px] px-3 text-[13px] transition-[font-weight] select-none', value === v ? 'font-semibold text-t1' : 'font-medium text-t2')}
        >
          {label}
        </button>
      ))}
    </div>
  )
}

/** Text with a light sweep while an agent works. */
export function Live({ children, className }: { children: React.ReactNode; className?: string }) {
  return <span className={cn('shimmer', className)}>{children}</span>
}
