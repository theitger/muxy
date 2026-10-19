import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'

/** UIKit's push curve, near enough. */
const EASE = 'cubic-bezier(0.32, 0.72, 0, 1)'
const DURATION = 380
const EDGE = 28

/**
 * A navigation stack of two levels, like UINavigationController: the page
 * slides in over the list, which shifts left and dims; it slides out on
 * back, or follows your thumb when you swipe from the left edge.
 *
 * `animate` false on a removal: it is already gone (swiped out, or the
 * system's own back gesture in Safari drew its own transition).
 */
export function Stack({
  base,
  page,
  pageKey,
  animate,
  onSwipeBack,
}: {
  base: ReactNode
  page: ReactNode | null
  pageKey: string | null
  animate: boolean
  onSwipeBack: () => void
}) {
  const [shownKey, setShownKey] = useState<string | null>(pageKey)
  const last = useRef<ReactNode>(page)
  const top = useRef<HTMLDivElement>(null)
  const under = useRef<HTMLDivElement>(null)
  const shade = useRef<HTMLDivElement>(null)

  // Keep showing the page while it slides out.
  if (pageKey && page) last.current = page
  if (pageKey && shownKey !== pageKey) setShownKey(pageKey)
  const shown = shownKey ? { key: shownKey, node: pageKey ? page : last.current } : null

  const place = (progress: number, transition: boolean) => {
    // progress 0: the page covers all; 1: gone to the right.
    const t = transition ? `transform ${DURATION}ms ${EASE}, opacity ${DURATION}ms ${EASE}` : 'none'
    if (top.current) {
      top.current.style.transition = t
      top.current.style.transform = `translate3d(${progress * 100}%, 0, 0)`
    }
    if (under.current) {
      under.current.style.transition = t
      under.current.style.transform = `translate3d(${(1 - progress) * -28}%, 0, 0)`
    }
    if (shade.current) {
      shade.current.style.transition = t
      shade.current.style.opacity = String((1 - progress) * 0.12)
    }
  }

  // In: from the right edge.
  const entered = useRef<string | null>(null)
  useLayoutEffect(() => {
    if (!shown || entered.current === shown.key) return
    entered.current = shown.key
    place(1, false)
    top.current?.getBoundingClientRect()
    requestAnimationFrame(() => place(0, true))
  }, [shownKey])

  // Out: back to the right, then gone.
  useLayoutEffect(() => {
    if (pageKey || !shownKey) return
    const done = () => {
      entered.current = null
      last.current = null
      setShownKey(null)
      if (under.current) {
        under.current.style.transition = 'none'
        under.current.style.transform = ''
      }
    }
    if (!animate) return done()
    place(1, true)
    const timer = setTimeout(done, DURATION)
    return () => clearTimeout(timer)
  }, [pageKey])

  // Swipe from the left edge, as everywhere on iOS.
  useEffect(() => {
    const el = top.current
    if (!el || !shownKey) return
    let start: { x: number; y: number; t: number } | null = null
    let dragging = false
    let last = { x: 0, t: 0 }
    const width = () => el.getBoundingClientRect().width
    const onStart = (e: TouchEvent) => {
      const touch = e.touches[0]
      if (e.touches.length !== 1 || touch.clientX - el.getBoundingClientRect().left > EDGE) return
      start = { x: touch.clientX, y: touch.clientY, t: e.timeStamp }
      last = { x: touch.clientX, t: e.timeStamp }
      dragging = false
    }
    const onMove = (e: TouchEvent) => {
      if (!start) return
      const touch = e.touches[0]
      const dx = touch.clientX - start.x
      const dy = touch.clientY - start.y
      if (!dragging) {
        if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) return void (start = null)
        if (dx < 8) return
        dragging = true
        ;(document.activeElement as HTMLElement | null)?.blur?.()
      }
      e.preventDefault()
      last = { x: touch.clientX, t: e.timeStamp }
      place(Math.max(0, dx) / width(), false)
    }
    const onEnd = (e: TouchEvent) => {
      if (!start || !dragging) return void (start = null)
      const x = e.changedTouches[0].clientX
      const dx = x - start.x
      const velocity = (x - last.x) / Math.max(1, e.timeStamp - last.t)
      start = null
      dragging = false
      if (dx > width() * 0.4 || velocity > 0.35) {
        place(1, true)
        setTimeout(onSwipeBack, DURATION * 0.8)
      } else {
        place(0, true)
      }
    }
    el.addEventListener('touchstart', onStart, { passive: true })
    el.addEventListener('touchmove', onMove, { passive: false })
    el.addEventListener('touchend', onEnd)
    el.addEventListener('touchcancel', onEnd)
    return () => {
      el.removeEventListener('touchstart', onStart)
      el.removeEventListener('touchmove', onMove)
      el.removeEventListener('touchend', onEnd)
      el.removeEventListener('touchcancel', onEnd)
    }
  }, [shownKey, onSwipeBack])

  return (
    <div className="relative h-full overflow-hidden">
      <div ref={under} className="absolute inset-0 will-change-transform" aria-hidden={!!shown}>
        {base}
        <div ref={shade} className="pointer-events-none absolute inset-0 bg-black opacity-0" />
      </div>
      {shown && (
        <div ref={top} className="absolute inset-0 shadow-[-12px_0_32px_rgb(0_0_0/0.12)] will-change-transform">
          {shown.node}
        </div>
      )}
    </div>
  )
}
