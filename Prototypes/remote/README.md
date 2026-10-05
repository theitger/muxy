# Muxy on the phone

The web app Muxy serves to a paired phone (Settings → Phone): the session
list, Claude as a chat built from its transcript, every tab's screen with
input and special keys.

- **Transport:** Muxy serves this app on port 47820 and the channel on
  47821, local network only.
- **Security:** the QR code carries a 32-byte secret in the URL fragment
  (never sent over the network). Each connection runs X25519 → HKDF-SHA256
  over secret + exchange → ChaCha20-Poly1305 per direction with counter
  nonces. Muxy acts on nothing before the phone proved the secret. Swift
  side: `Sources/muxy/Remote/RemoteCrypto.swift`; keep both in sync.
- **Known limits:** the page itself is served over plain HTTP, so an
  active attacker on the same network could swap the app's code and steal
  the secret on the next load. Screens are text only (no colors yet).

```sh
pnpm install
pnpm build        # dist/index.html — make-app.sh bundles it into Muxy.app
pnpm dev --host   # development against a running Muxy (channel on 47821)
```

Vite + React + Tailwind + shadcn; crypto from the audited `@noble/*`
libraries (Web Crypto needs HTTPS, which a LAN page doesn't have). The
bundled font is a subset of IosevkaTerm Nerd Font (SIL OFL 1.1).
