import { QrCode, ShieldAlert, WifiOff } from 'lucide-react'
import type { ChannelState } from '@/lib/channel'
import { t } from '@/lib/i18n'
import { forgetPairing } from '@/lib/useMuxy'

/** Before anything works: not paired yet, Muxy unreachable, or the key was replaced. */
export function Pair({ paired, state }: { paired: boolean; state: ChannelState }) {
  const [Icon, title, text] = !paired
    ? [
        QrCode,
        t('Pair with Muxy'),
        t('On the Mac, open Muxy, Settings (⌘,), Phone, and scan the QR code with the camera. Then in Safari: Share, Add to Home Screen. Muxy then starts like an app.'),
      ]
    : state === 'rejected'
      ? [ShieldAlert, t('Pairing expired'), t('Muxy has a new key. Scan the QR code in Settings under Phone again.')]
      : [WifiOff, t('Muxy unreachable'), t('Is the Mac awake and Muxy open, with phone access on? Muxy keeps trying.')]

  return (
    <div className="fade-in flex h-full flex-col items-center justify-center gap-4 bg-bg px-8 text-center">
      <div className="grid size-16 place-items-center rounded-[18px] bg-raised text-t2 shadow-[0_1px_3px_rgb(0_0_0/0.08)]">
        <Icon className={state === 'connecting' && paired ? 'size-7 pulse-soft' : 'size-7'} />
      </div>
      <h1 className="text-[22px] font-bold text-t1">{paired && state === 'connecting' ? t('Connecting …') : title}</h1>
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
          {t('Remove pairing')}
        </button>
      )}
    </div>
  )
}
