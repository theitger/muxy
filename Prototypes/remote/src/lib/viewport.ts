import { useEffect } from 'react'

/**
 * iOS shrinks only the *visual* viewport when the keyboard opens; fixed
 * elements would hide behind it. The app is sized to the visual viewport
 * instead (`--app-h`, `--app-top`), so the dock always sits right on top
 * of the keyboard, like a native input bar.
 */
export function useVisualViewport() {
  useEffect(() => {
    const vv = window.visualViewport
    if (!vv) return
    const root = document.documentElement
    const update = () => {
      root.style.setProperty('--app-h', `${vv.height}px`)
      root.style.setProperty('--app-top', `${vv.offsetTop}px`)
      root.classList.toggle('keyboard-open', window.innerHeight - vv.height > 120)
    }
    update()
    vv.addEventListener('resize', update)
    vv.addEventListener('scroll', update)
    return () => {
      vv.removeEventListener('resize', update)
      vv.removeEventListener('scroll', update)
    }
  }, [])
}
