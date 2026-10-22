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
import { t } from '@/lib/i18n'
import { cn } from '@/lib/utils'
import { agentName, type Agent, type AgentKind, type PRStatus, type Session } from '@/lib/protocol'
import { AgentLogo } from './flow'

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
  if (s.quorum?.running && s.agent !== 'blocked' && s.agent !== 'failed') {
    return { text: s.quorum.summary, tone: 'blue', live: true }
  }
  switch (s.agent) {
    case 'blocked':
      return { text: t('%s is waiting for your answer', who), tone: 'orange' }
    case 'failed':
      return { text: t('%s hit an error', who), tone: 'red' }
    case 'working':
      return { text: s.activity ?? t('%s is working', who), tone: 'blue', live: true }
    case 'idle':
      return s.attention ? { text: t('%s is done', who), tone: 'green' } : { text: t('%s is ready', who), tone: 'neutral' }
    default:
      return s.attention ? { text: s.notice ?? t('New output'), tone: 'orange' } : { text: s.subtitle || s.directory, tone: 'neutral' }
  }
}

/** Muxy's SessionTile: what a session is and whether it wants you. */
export function SessionTile({ agent, attention, isGit, kind, size = 36 }: { agent: Agent; attention: boolean; isGit: boolean; kind?: AgentKind; size?: number }) {
  // Working or ready, the agent itself shows; states that want something keep their sign.
  if (kind && (agent === 'working' || (agent === 'idle' && !attention))) {
    return (
      <div className={cn('grid shrink-0 place-items-center', agent === 'working' ? 'bg-tone-blue-soft' : 'bg-tone-neutral-soft')} style={{ width: size, height: size, borderRadius: size * 0.28 }}>
        <AgentLogo kind={kind} size={size * 0.5} className={cn(agent === 'working' && 'pulse-soft', agent === 'idle' && 'opacity-60')} />
      </div>
    )
  }
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
  none: [null, 'neutral', t('No checks')],
  running: [CircleDashed, 'blue', t('Checks running')],
  fixing: [Wrench, 'yellow', t('Checks failed, being fixed')],
  failed: [X, 'red', t('Checks failed')],
  conflicts: [GitMerge, 'red', t('Merge conflicts')],
  draft: [Pencil, 'neutral', t('Draft')],
  waiting: [Hourglass, 'neutral', t('Checks passed, merge blocked')],
  ready: [Check, 'green', t('Ready to merge')],
  merged: [GitMerge, 'green', t('Merged')],
  closed: [X, 'neutral', t('Closed without merging')],
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

/** "just now", "4 min ago", "2h ago" — refreshed every half minute. */
export function Ago({ since }: { since?: number }) {
  const [, tick] = useState(0)
  useEffect(() => {
    const id = setInterval(() => tick((n) => n + 1), 30_000)
    return () => clearInterval(id)
  }, [])
  if (!since) return null
  const s = Math.max(0, Date.now() / 1000 - since)
  const text = s < 60 ? t('just now') : s < 3600 ? t('%d min ago', Math.floor(s / 60)) : s < 86400 ? t('%dh ago', Math.floor(s / 3600)) : t('%dd ago', Math.floor(s / 86400))
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
