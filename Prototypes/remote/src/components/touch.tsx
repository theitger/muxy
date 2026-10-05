import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

/**
 * A plain button that gives way under the thumb and never takes the
 * focus — tapping it while typing keeps the keyboard up.
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
    <button
      type="button"
      aria-label={label}
      disabled={disabled}
      onPointerDown={(e) => e.preventDefault()}
      onClick={onPress}
      className={cn(
        'inline-flex touch-manipulation items-center justify-center outline-none transition-[transform,background-color] duration-100 select-none active:scale-[0.95] focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-35',
        className,
      )}
    >
      {children}
    </button>
  )
}
