// The phone's half of RemoteCrypto.swift — change both together.
// Pairing secret (32 bytes, from the QR code's fragment) + a fresh X25519
// exchange per connection → HKDF-SHA256 → one ChaCha20-Poly1305 key per
// direction, nonce = 4 zero bytes + 64-bit big-endian counter.
import { chacha20poly1305 } from '@noble/ciphers/chacha.js'
import { x25519 } from '@noble/curves/ed25519.js'
import { hkdf } from '@noble/hashes/hkdf.js'
import { sha256 } from '@noble/hashes/sha2.js'

const INFO = new TextEncoder().encode('muxy-remote v1')

export type Keys = { send: Uint8Array; receive: Uint8Array }

function concat(...parts: Uint8Array[]) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let offset = 0
  for (const p of parts) {
    out.set(p, offset)
    offset += p.length
  }
  return out
}

export function newEphemeral() {
  const secretKey = x25519.utils.randomSecretKey()
  return { secretKey, publicKey: x25519.getPublicKey(secretKey) }
}

export function deriveClientKeys(secret: Uint8Array, clientSecretKey: Uint8Array, clientPublic: Uint8Array, serverPublic: Uint8Array): Keys {
  const dh = x25519.getSharedSecret(clientSecretKey, serverPublic)
  const okm = hkdf(sha256, concat(secret, dh), concat(serverPublic, clientPublic), INFO, 64)
  // First half: phone → muxy, second half: muxy → phone.
  return { send: okm.slice(0, 32), receive: okm.slice(32) }
}

export function nonce(counter: number) {
  const n = new Uint8Array(12)
  new DataView(n.buffer).setBigUint64(4, BigInt(counter))
  return n
}

export function seal(plain: Uint8Array, key: Uint8Array, counter: number) {
  return chacha20poly1305(key, nonce(counter)).encrypt(plain)
}

/** Throws when the frame wasn't sealed with this key and counter. */
export function open(frame: Uint8Array, key: Uint8Array, counter: number) {
  return chacha20poly1305(key, nonce(counter)).decrypt(frame)
}

export { concat }

export function fromBase64URL(text: string) {
  const b64 = text.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((text.length + 3) % 4)
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
}
