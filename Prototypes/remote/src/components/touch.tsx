import { useRef, useState, type ReactNode } from 'react'
import { cn } from '@/lib/utils'

/**
 * A pressable that feels like a key: it gives way under the thumb and
 * ticks. iOS only ticks for a real tap on a switch (since 26.5, not for
 * scripted clicks), so an invisible `<input switch>` lies over the face
 * and the tap lands on it directly.
 */
export function Tap({
  onPress,
  children,
  className,
  label,
  disabled,
}: {
  onPress: () => void
  children: ReactNode
  className?: string
  label?: string
  disabled?: boolean
}) {
  return (
    <label
      aria-label={label}
      className={cn(
        'relative inline-flex cursor-pointer touch-manipulation items-center justify-center transition-transform duration-75 select-none active:scale-[0.94]',
        disabled && 'pointer-events-none opacity-35',
        className,
      )}
    >
      <input
        type="checkbox"
        ref={(el) => el?.setAttribute('switch', '')}
        onChange={() => onPress()}
        disabled={disabled}
        className="absolute inset-0 z-10 m-0 size-full cursor-pointer appearance-none opacity-0"
        tabIndex={-1}
        aria-hidden
      />
      {children}
    </label>
  )
}

/** A key cap in the iOS keyboard's style. */
export function KeyCap({
  onPress,
  children,
  label,
  active,
  wide,
}: {
  onPress: () => void
  children: ReactNode
  label: string
  active?: boolean
  wide?: boolean
}) {
  return (
    <Tap
      onPress={onPress}
      label={label}
      className={cn(
        'h-10 shrink-0 rounded-[9px] text-[15px] font-medium shadow-[0_1px_0_rgb(0_0_0/0.28)]',
        wide ? 'min-w-[52px] px-3' : 'min-w-[42px] px-2',
        active ? 'bg-t1 text-bg' : 'bg-keycap text-t1',
      )}
    >
      {children}
    </Tap>
  )
}

export type Arrow = 'up' | 'down' | 'left' | 'right'

/**
 * Drag to move the cursor — every ~22 px is one arrow press, like the
 * cursor drag on the iOS space bar. The arrows show where you're going.
 */
export function Trackpad({ onArrow }: { onArrow: (arrow: Arrow) => void }) {
  const origin = useRef<{ x: number; y: number } | null>(null)
  const [dir, setDir] = useState<Arrow | null>(null)
  const STEP = 22

  return (
    <div
      role="slider"
      aria-label="Pfeiltasten: ziehen"
      aria-valuetext={dir ?? 'bereit'}
      className={cn(
        'relative grid h-10 w-[76px] shrink-0 touch-none place-items-center rounded-[9px] shadow-[0_1px_0_rgb(0_0_0/0.28)] transition-colors select-none',
        dir ? 'bg-t1 text-bg' : 'bg-keycap text-t3',
      )}
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId)
        origin.current = { x: e.clientX, y: e.clientY }
      }}
      onPointerMove={(e) => {
        const o = origin.current
        if (!o) return
        const dx = e.clientX - o.x
        const dy = e.clientY - o.y
        if (Math.max(Math.abs(dx), Math.abs(dy)) < STEP) return
        const arrow: Arrow = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 'right' : 'left') : dy > 0 ? 'down' : 'up'
        setDir(arrow)
        onArrow(arrow)
        origin.current = { x: e.clientX, y: e.clientY }
      }}
      onPointerUp={() => {
        origin.current = null
        setDir(null)
      }}
      onPointerCancel={() => {
        origin.current = null
        setDir(null)
      }}
    >
      <svg viewBox="0 0 40 24" className="h-6 w-10" fill="currentColor" aria-hidden>
        <path d="M20 1l3 3.5h-6zM20 23l-3-3.5h6zM6 12l3.5-3v6zM34 12l-3.5 3V9z" opacity={dir ? 0.35 : 1} />
        {dir === 'up' && <path d="M20 1l3 3.5h-6z" />}
        {dir === 'down' && <path d="M20 23l-3-3.5h6z" />}
        {dir === 'left' && <path d="M6 12l3.5-3v6z" />}
        {dir === 'right' && <path d="M34 12l-3.5 3V9z" />}
        <circle cx="20" cy="12" r="3.2" />
      </svg>
    </div>
  )
}
