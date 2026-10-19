import { QrCode, ShieldAlert, WifiOff } from 'lucide-react'
import type { ChannelState } from '@/lib/channel'
import { forgetPairing } from '@/lib/useMuxy'

/** Before anything works: not paired yet, Muxy unreachable, or the key was replaced. */
export function Pair({ paired, state }: { paired: boolean; state: ChannelState }) {
  const [Icon, title, text] = !paired
    ? [
        QrCode,
        'Mit Muxy koppeln',
        'Öffne auf dem Mac Muxy, Einstellungen (⌘,), Handy, und scanne den QR-Code mit der Kamera. Danach in Safari: Teilen, Zum Home-Bildschirm. Dann startet Muxy wie eine App.',
      ]
    : state === 'rejected'
      ? [ShieldAlert, 'Kopplung abgelaufen', 'Muxy hat einen neuen Schlüssel. Scanne den QR-Code in den Einstellungen unter Handy noch einmal.']
      : [WifiOff, 'Muxy nicht erreichbar', 'Ist der Mac wach und Muxy offen, mit eingeschaltetem Handy-Zugang? Muxy versucht es weiter.']

  return (
    <div className="fade-in flex h-full flex-col items-center justify-center gap-4 bg-bg px-8 text-center">
      <div className="grid size-16 place-items-center rounded-[18px] bg-raised text-t2 shadow-[0_1px_3px_rgb(0_0_0/0.08)]">
        <Icon className={state === 'connecting' && paired ? 'size-7 pulse-soft' : 'size-7'} />
      </div>
      <h1 className="text-[22px] font-bold text-t1">{paired && state === 'connecting' ? 'Verbinde …' : title}</h1>
      <p className="max-w-[310px] text-[15.5px] leading-relaxed text-t3">{text}</p>
      {paired && state === 'rejected' && (
        <button
          type="button"
          onClick={() => {
            forgetPairing()
            location.reload()
          }}
          className="mt-2 h-11 rounded-full bg-raised px-5 text-[16px] font-medium text-tone-red active:opacity-60"
        >
          Kopplung entfernen
        </button>
      )}
    </div>
  )
}
