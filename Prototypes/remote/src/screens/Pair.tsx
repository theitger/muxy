import { QrCode, ShieldAlert, WifiOff } from 'lucide-react'
import type { ChannelState } from '@/lib/channel'
import { forgetPairing } from '@/lib/useMuxy'

/** Before anything works: not paired yet, Muxy unreachable, or the key was replaced. */
export function Pair({ paired, state }: { paired: boolean; state: ChannelState }) {
  const [Icon, title, text] = !paired
    ? [
        QrCode,
        'Mit Muxy koppeln',
        'Scanne den QR-Code aus Muxy → Einstellungen (⌘,) → Handy mit der Kamera. Für den Home-Bildschirm danach in Safari: Teilen → Zum Home-Bildschirm.',
      ]
    : state === 'rejected'
      ? [ShieldAlert, 'Kopplung abgelaufen', 'Muxy hat einen neuen Schlüssel. Scanne den QR-Code in Muxy → Einstellungen → Handy erneut.']
      : [WifiOff, 'Muxy nicht erreichbar', 'Ist der Mac wach und Muxy offen (Einstellungen → Handy)? Es wird weiter versucht.']

  return (
    <div className="flex h-full flex-col items-center justify-center gap-4 bg-surface px-8 text-center">
      <div className="grid size-14 place-items-center rounded-2xl bg-active text-t2">
        <Icon className={state === 'connecting' && paired ? 'size-7 pulse-soft' : 'size-7'} />
      </div>
      <h1 className="text-[20px] font-semibold text-t1">{paired && state === 'connecting' ? 'Verbinde …' : title}</h1>
      <p className="max-w-[300px] text-[14.5px] leading-relaxed text-t3">{text}</p>
      {paired && state === 'rejected' && (
        <button
          type="button"
          onClick={() => {
            forgetPairing()
            location.reload()
          }}
          className="mt-2 h-10 rounded-xl border border-hair bg-raised px-4 text-[14px] font-medium text-t1"
        >
          Kopplung entfernen
        </button>
      )}
    </div>
  )
}
