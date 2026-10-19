import { useRef, useState, type ReactNode } from 'react'
import { t } from '@/lib/i18n'
import { claudePath, codexPath } from '@/lib/marks'
import { actionable, type AgentKind, type Session } from '@/lib/protocol'
import { cn } from '@/lib/utils'

/** Claude's or Codex's own mark, in its own color. */
export function AgentLogo({ kind, size = 16, className }: { kind?: AgentKind; size?: number; className?: string }) {
  if (!kind) return null
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} className={cn(kind === 'claude' ? 'text-claude' : 'text-codex', className)} aria-label={kind === 'claude' ? 'Claude' : 'Codex'}>
      <path fill="currentColor" fillRule="evenodd" clipRule="evenodd" d={kind === 'claude' ? claudePath : codexPath} />
    </svg>
  )
}

/** The session's suggested next step as a button; nothing when there is none to take. */
export function StepButton({ session, onStep, size = 'md' }: { session: Session; onStep: (session: Session) => void; size?: 'sm' | 'md' }) {
  const [sent, setSent] = useState(false)
  const next = session.next
  if (!next || !actionable(next.kind)) return null
  return (
    <button
      type="button"
      disabled={sent}
      onClick={(e) => {
        e.stopPropagation()
        setSent(true)
        onStep(session)
        // The Mac moves on or doesn't: either way, tappable again soon.
        setTimeout(() => setSent(false), 4000)
      }}
      className={cn(
        'shrink-0 rounded-full bg-brand font-semibold text-bg transition-opacity active:opacity-70 disabled:opacity-50',
        size === 'sm' ? 'h-[28px] px-3 text-[13.5px]' : 'h-[36px] px-4 text-[15px]',
      )}
    >
      {next.title}
    </button>
  )
}

/** What muxy knows beyond the agent, in words: checks, collisions, quorum. */
export function Facts({ session, className }: { session: Session; className?: string }) {
  const facts: { text: string; tone: string }[] = []
  if (session.proof === 'running') facts.push({ text: t('checking'), tone: 'text-tone-blue' })
  if (session.proof === 'failed') facts.push({ text: t('checks fail'), tone: 'text-tone-red' })
  if (session.proof === 'passed') facts.push({ text: t('proven'), tone: 'text-tone-green' })
  for (const other of session.collisions?.slice(0, 2) ?? []) facts.push({ text: t('collides: %s', other), tone: 'text-tone-orange' })
  if (session.quorum) facts.push({ text: session.quorum.summary, tone: session.quorum.running ? 'text-tone-blue' : session.quorum.clean ? 'text-tone-green' : 'text-t3' })
  if (!facts.length) return null
  return (
    <div className={cn('flex flex-wrap gap-x-2.5 gap-y-0.5 text-[13px]', className)}>
      {facts.map((f) => (
        <span key={f.text} className={f.tone}>
          {f.text}
        </span>
      ))}
    </div>
  )
}

/**
 * A list row you can swipe left, like Mail: the action behind it shows,
 * a long swipe takes it right away, a tap on it too.
 */
export function SwipeRow({ children, action, onAction }: { children: ReactNode; action?: string; onAction?: () => void }) {
  const row = useRef<HTMLDivElement>(null)
  const start = useRef<{ x: number; y: number; dx: number; horizontal: boolean | null } | null>(null)
  const [open, setOpen] = useState(false)
  const width = 112

  const place = (x: number, animate: boolean) => {
    if (!row.current) return
    row.current.style.transition = animate ? 'transform 300ms cubic-bezier(0.32, 0.72, 0, 1)' : 'none'
    row.current.style.transform = `translate3d(${x}px, 0, 0)`
  }

  if (!action || !onAction) return <>{children}</>

  return (
    <div className="relative overflow-hidden">
      <button
        type="button"
        onClick={() => {
          place(0, true)
          setOpen(false)
          onAction()
        }}
        className="absolute inset-y-0 right-0 flex items-center justify-center bg-brand px-4 text-[14px] font-semibold text-bg"
        style={{ width }}
        tabIndex={open ? 0 : -1}
      >
        <span className="leading-tight">{action}</span>
      </button>
      <div
        ref={row}
        className="relative bg-raised"
        onTouchStart={(e) => {
          const touch = e.touches[0]
          start.current = { x: touch.clientX, y: touch.clientY, dx: open ? -width : 0, horizontal: null }
        }}
        onTouchMove={(e) => {
          const s = start.current
          if (!s) return
          const touch = e.touches[0]
          const dx = touch.clientX - s.x
          const dy = touch.clientY - s.y
          if (s.horizontal === null && (Math.abs(dx) > 8 || Math.abs(dy) > 8)) s.horizontal = Math.abs(dx) > Math.abs(dy)
          if (!s.horizontal) return
          const x = Math.min(0, Math.max(-width * 2.2, s.dx + dx))
          place(x, false)
        }}
        onTouchEnd={(e) => {
          const s = start.current
          start.current = null
          if (!s?.horizontal) return
          const x = s.dx + (e.changedTouches[0].clientX - s.x)
          if (x < -width * 1.8) {
            // A long swipe takes the action.
            place(0, true)
            setOpen(false)
            onAction()
          } else if (x < -width / 2) {
            place(-width, true)
            setOpen(true)
          } else {
            place(0, true)
            setOpen(false)
          }
        }}
        onClickCapture={(e) => {
          // A tap on a row that is swiped open just closes it.
          if (open) {
            e.stopPropagation()
            e.preventDefault()
            place(0, true)
            setOpen(false)
          }
        }}
      >
        {children}
      </div>
    </div>
  )
}
