# Muxy on the phone

The web app Muxy serves to a paired phone (Settings → Phone), built to feel
like a native iOS app: a navigation stack with the edge swipe back, sheets
you drag away, inset lists.

- **Home:** what waits on you on top, with the agent's question as
  buttons right in the list; then what runs; then the rest by repository.
- **Session:** Claude or Codex as a conversation built from the agent's own
  log (tool calls folded into steps), or the tab's real screen with a key
  row over the keyboard. Shell tabs are a terminal with your history as
  suggestions.
- **New session:** like ⌘N: Claude, Codex or a plain terminal, a task, a
  repository, a worktree or not.

- **Transport:** through a relay (`Relay/`, which also serves this app
  over HTTPS; the QR code carries `#r=<room>&k=<secret>`) or, without
  one, straight from Muxy on the local network (app on port 47820,
  channel on 47821).
- **Security:** the QR code carries a 32-byte secret in the URL fragment
  (never sent over the network). Each connection runs X25519 → HKDF-SHA256
  over secret + exchange → ChaCha20-Poly1305 per direction with counter
  nonces. Muxy acts on nothing before the phone proved the secret. Swift
  side: `Sources/muxy/Remote/RemoteCrypto.swift`; keep both in sync.
- **Known limits:** whoever controls the server that serves this page
  could swap its code and steal the secret on the next load — the relay
  host, or on the local-network path anyone able to tamper with plain
  HTTP there. Screens are text only (no colors yet).

```sh
pnpm install
pnpm build        # dist/index.html — make-app.sh bundles it into Muxy.app
pnpm dev --host   # development against a running Muxy (channel on 47821)
                  # open /#demo for made-up sessions, nothing connected
```

Vite + React + Tailwind + shadcn; crypto from the audited `@noble/*`
libraries (Web Crypto needs HTTPS, which a LAN page doesn't have). The
bundled font is a subset of IosevkaTerm Nerd Font (SIL OFL 1.1).
