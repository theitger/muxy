import { Lock as LockIcon, ScanFace, ShieldCheck } from 'lucide-react'
import { useEffect, useState } from 'react'
import { MAC_NAME } from '@/data'

/**
 * Two ways in: the push (tap → straight into the session that wants you)
 * or opening the app (Face ID → overview). Face ID is a passkey the Mac
 * verifies, not the relay.
 */
export function Lock({ onUnlock }: { onUnlock: (sessionId?: string) => void }) {
  const [showPush, setShowPush] = useState(false)
  const [scanning, setScanning] = useState<string | null | undefined>(undefined)

  useEffect(() => {
    const t = setTimeout(() => setShowPush(true), 700)
    return () => clearTimeout(t)
  }, [])

  function unlock(target?: string) {
    setScanning(target ?? null)
    setTimeout(() => onUnlock(target), 650)
  }

  const now = new Date()
  const time = now.toLocaleTimeString('de-DE', { hour: '2-digit', minute: '2-digit' })

  return (
    <div className="relative flex h-full flex-col items-center bg-surface px-4">
      <div className="mt-14 text-center">
        <div className="text-[13px] font-medium text-t3">
          {now.toLocaleDateString('de-DE', { weekday: 'long', day: 'numeric', month: 'long' })}
        </div>
        <div className="text-[64px] leading-none font-semibold tracking-tight text-t1 tabular-nums">{time}</div>
      </div>

      <button
        type="button"
        onClick={() => unlock('badge')}
        className={`mt-8 w-full max-w-[400px] rounded-[22px] border border-hair bg-raised/90 p-3 text-left shadow-[0_8px_30px_rgb(0_0_0/0.08)] backdrop-blur transition-all duration-500 ${
          showPush ? 'translate-y-0 opacity-100' : '-translate-y-3 opacity-0'
        }`}
      >
        <div className="flex items-start gap-3">
          <MuxyMark />
          <div className="min-w-0 flex-1">
            <div className="flex items-baseline justify-between gap-2">
              <span className="text-[13px] font-semibold text-t1">Muxy</span>
              <span className="text-[12px] text-t4">jetzt</span>
            </div>
            <div className="text-[14px] font-semibold text-t1">PR-Badge ehrlich machen braucht dich</div>
            <div className="truncate font-mono text-[12.5px] text-t3">git push -u origin fix/honest-pr-badge</div>
          </div>
        </div>
      </button>
      <p className="mt-2 text-[12px] text-t4">Push antippen → direkt in die Session</p>

      <div className="mt-auto mb-10 flex w-full max-w-[400px] flex-col items-center gap-4">
        <div className="flex items-center gap-1.5 rounded-full bg-tone-neutral-soft px-3 py-1.5 text-[12px] text-t3">
          <ShieldCheck className="size-3.5" strokeWidth={2.4} />
          {MAC_NAME} · Ende-zu-Ende verschlüsselt
        </div>
        <button
          type="button"
          onClick={() => unlock()}
          className="flex h-12 w-full items-center justify-center gap-2 rounded-2xl bg-t1 text-[15px] font-semibold text-bg active:opacity-80"
        >
          {scanning !== undefined ? (
            <>
              <ScanFace className="size-5 pulse-soft" /> Face ID …
            </>
          ) : (
            <>
              <LockIcon className="size-4" /> Mit Face ID entsperren
            </>
          )}
        </button>
      </div>
    </div>
  )
}

export function MuxyMark({ size = 38 }: { size?: number }) {
  return (
    <div
      className="grid shrink-0 place-items-center bg-[#2a2a28] text-[#f4f4f0]"
      style={{ width: size, height: size, borderRadius: size * 0.26 }}
      aria-hidden
    >
      <svg viewBox="0 0 24 24" style={{ width: size * 0.56, height: size * 0.56 }} fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
        <path d="M5 8l4 4-4 4" />
        <path d="M12 16h7" />
      </svg>
    </div>
  )
}
