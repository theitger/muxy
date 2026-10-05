import { concat, deriveClientKeys, newEphemeral, open, seal, type Keys } from './crypto'

export type ChannelState = 'connecting' | 'open' | 'rejected' | 'offline'

/**
 * The encrypted line to Muxy (RemoteServer.swift). Muxy sends its
 * ephemeral key first; the phone answers with its own plus a sealed
 * "auth" — muxy talks only after that opens with the pairing secret.
 * Reconnects by itself; a rejected secret stops it (pair again).
 */
export class Channel {
  private ws: WebSocket | null = null
  private keys: Keys | null = null
  private sendCounter = 0
  private receiveCounter = 0
  private retry = 0
  private timer: number | undefined
  private stopped = false
  private everOpened = false

  private url: string
  private secret: Uint8Array
  private onMessage: (message: Record<string, unknown>) => void
  private onState: (state: ChannelState) => void

  constructor(
    url: string,
    secret: Uint8Array,
    onMessage: (message: Record<string, unknown>) => void,
    onState: (state: ChannelState) => void,
  ) {
    this.url = url
    this.secret = secret
    this.onMessage = onMessage
    this.onState = onState
  }

  start() {
    this.stopped = false
    this.connect()
  }

  stop() {
    this.stopped = true
    clearTimeout(this.timer)
    this.ws?.close()
  }

  send(message: Record<string, unknown>) {
    if (!this.keys || this.ws?.readyState !== WebSocket.OPEN) return false
    const sealed = seal(new TextEncoder().encode(JSON.stringify(message)), this.keys.send, this.sendCounter++)
    this.ws.send(sealed)
    return true
  }

  private connect() {
    this.onState(this.everOpened ? 'offline' : 'connecting')
    this.keys = null
    this.sendCounter = 0
    this.receiveCounter = 0
    const ephemeral = newEphemeral()
    const ws = new WebSocket(this.url)
    ws.binaryType = 'arraybuffer'
    this.ws = ws
    let authenticated = false
    let gotHello = false

    ws.onmessage = (event) => {
      const frame = new Uint8Array(event.data as ArrayBuffer)
      if (!this.keys) {
        // [0x01][muxy's ephemeral key]
        if (frame[0] !== 0x01 || frame.length !== 33) return ws.close()
        gotHello = true
        const serverPublic = frame.slice(1)
        this.keys = deriveClientKeys(this.secret, ephemeral.secretKey, ephemeral.publicKey, serverPublic)
        const auth = seal(new TextEncoder().encode(JSON.stringify({ t: 'auth' })), this.keys.send, 0)
        this.sendCounter = 1
        ws.send(concat(new Uint8Array([0x02]), ephemeral.publicKey, auth))
        return
      }
      let plain: Uint8Array
      try {
        plain = open(frame, this.keys.receive, this.receiveCounter++)
      } catch {
        return ws.close()
      }
      if (!authenticated) {
        authenticated = true
        this.everOpened = true
        this.retry = 0
        this.onState('open')
      }
      this.onMessage(JSON.parse(new TextDecoder().decode(plain)))
    }

    ws.onclose = () => {
      if (this.ws !== ws) return
      this.keys = null
      if (this.stopped) return
      // Muxy hangs up right after the handshake when the secret is wrong.
      if (gotHello && !authenticated && this.retry >= 1) {
        this.onState('rejected')
        return
      }
      this.onState(this.everOpened ? 'offline' : 'connecting')
      const delay = Math.min(8000, 500 * 2 ** this.retry++)
      this.timer = window.setTimeout(() => this.connect(), delay)
    }
  }
}
