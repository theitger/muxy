import { useEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

const EASE = 'cubic-bezier(0.32, 0.72, 0, 1)'

/**
 * A sheet from the bottom, like iOS's: rises over a dimmed page, and goes
 * when you drag it down by its grabber or header, tap outside, or are done.
 */
export function BottomSheet({
  open,
  onClose,
  title,
  action,
  closeLabel = 'Abbrechen',
  children,
}: {
  open: boolean
  onClose: () => void
  title: string
  action?: ReactNode
  closeLabel?: string
  children: ReactNode
}) {
  const [mounted, setMounted] = useState(open)
  const sheet = useRef<HTMLDivElement>(null)
  const backdrop = useRef<HTMLDivElement>(null)

  if (open && !mounted) setMounted(true)

  const place = (y: string, shade: number, transition = true) => {
    const t = transition ? `transform 420ms ${EASE}` : 'none'
    if (sheet.current) {
      sheet.current.style.transition = t
      sheet.current.style.transform = `translate3d(0, ${y}, 0)`
    }
    if (backdrop.current) {
      backdrop.current.style.transition = transition ? `opacity 420ms ${EASE}` : 'none'
      backdrop.current.style.opacity = String(shade)
    }
  }

  useEffect(() => {
    if (!mounted) return
    if (open) {
      place('100%', 0, false)
      sheet.current?.getBoundingClientRect()
      requestAnimationFrame(() => place('0px', 1))
      return
    }
    ;(document.activeElement as HTMLElement | null)?.blur?.()
    place('100%', 0)
    const timer = setTimeout(() => setMounted(false), 420)
    return () => clearTimeout(timer)
  }, [open, mounted])

  // Drag down by the top part.
  const drag = useRef<{ y: number; t: number; last: number; lastT: number } | null>(null)
  const onStart = (e: React.TouchEvent) => {
    const t = e.touches[0]
    drag.current = { y: t.clientY, t: e.timeStamp, last: t.clientY, lastT: e.timeStamp }
  }
  const onMove = (e: React.TouchEvent) => {
    const d = drag.current
    if (!d) return
    const y = e.touches[0].clientY
    const dy = Math.max(0, y - d.y)
    d.last = y
    d.lastT = e.timeStamp
    const height = sheet.current?.offsetHeight ?? 400
    place(`${dy}px`, 1 - Math.min(1, dy / height), false)
  }
  const onEnd = (e: React.TouchEvent) => {
    const d = drag.current
    if (!d) return
    drag.current = null
    const y = e.changedTouches[0].clientY
    const dy = y - d.y
    const velocity = (y - d.last) / Math.max(1, e.timeStamp - d.lastT)
    if (dy > 120 || velocity > 0.5) onClose()
    else place('0px', 1)
  }

  if (!mounted) return null
  return createPortal(
    <div className="app-frame z-50" role="dialog" aria-modal="true" aria-label={title}>
      <div ref={backdrop} onClick={onClose} className="absolute inset-0 bg-black/30 opacity-0" />
      <div
        ref={sheet}
        className="absolute inset-x-0 bottom-0 mx-auto flex max-h-[calc(100%-44px)] max-w-[560px] flex-col rounded-t-[14px] bg-bg shadow-[0_-8px_40px_rgb(0_0_0/0.18)]"
        style={{ transform: 'translate3d(0, 100%, 0)' }}
      >
        <div onTouchStart={onStart} onTouchMove={onMove} onTouchEnd={onEnd} className="shrink-0 touch-none select-none">
          <div className="mx-auto mt-[7px] h-[5px] w-9 rounded-full bg-t5/45" />
          <div className="grid h-12 grid-cols-[1fr_auto_1fr] items-center px-4">
            <button type="button" onClick={onClose} className="justify-self-start text-[17px] text-brand active:opacity-40">
              {closeLabel}
            </button>
            <h2 className="text-[17px] font-semibold text-t1">{title}</h2>
            <div className="justify-self-end">{action}</div>
          </div>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain pb-[calc(env(safe-area-inset-bottom,0px)+16px)]">{children}</div>
      </div>
    </div>,
    document.body,
  )
}
