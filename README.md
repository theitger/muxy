# Muxy

A native macOS terminal workspace for running many coding agents in
parallel — **real Ghostty rendering**, every session in one window, and a
quiet signal the moment an agent needs you.

- **It IS your Ghostty.** Muxy embeds [libghostty](https://ghostty.org) and
  loads your own `~/.config/ghostty/config` — theme, font, opacity, padding,
  everything, 1:1. Light/dark follows the system.
- **A session is what used to be a window.** `⌘N` opens one, you `cd`
  somewhere and start your agent; `⌘T` opens a tab right there. The sidebar
  sorts sessions by repository and shows branch and PR on its own — nothing
  to configure.
- **Agent-aware.** A Claude Code hook reports *working*, *done* and *needs
  you* per tab. The session's tile changes, the Dock shows a count, and a
  banner (click → that session) appears when Muxy is in the background.
- **PR status at a glance.** The PR badge follows the CI checks and
  GitHub's merge state: blue while checks run, yellow when they failed and
  something in the session is working on it, red when they failed or the
  PR has conflicts, grey for drafts and PRs GitHub still holds back
  (review, out-of-date branch, required check missing), green only when
  it could be merged right now.
- **Windows when you want them.** Drag a session from the sidebar and drop
  it anywhere — it opens as its own window right there; drop it on another
  window's sidebar and it moves in. Running processes don't notice.
- **On your phone (same Wi-Fi).** Settings → Phone shows a QR code; scan
  it and Safari becomes a remote for every session: the sidebar with agent
  state and PR badges, Claude as a chat with permission buttons, any tab's
  screen with a line to type into and the keys a phone lacks. Pairing puts
  a secret on the phone; every connection is end-to-end encrypted with it
  (fresh X25519 keys, ChaCha20-Poly1305). "Pair Again" locks all phones out.
- **English or German.** English by default; switch in Settings (`⌘,`).
- **Built to stay fast.** Exactly one terminal surface per window is
  attached; background sessions keep their PTY but cost no rendering. No
  animations while idle.

## Install

```sh
brew tap theitger/tap
brew trust theitger/tap        # Homebrew ≥ 6 requires tap trust
brew install --cask muxy
xattr -dr com.apple.quarantine /Applications/Muxy.app
```

The last line is needed because the app is ad-hoc signed (no Apple
Developer certificate) — without it Gatekeeper blocks the first launch as
"unverified developer".

### Build from source

```sh
git clone https://github.com/theitger/muxy && cd muxy
./Scripts/make-app.sh   # fetches the pinned GhosttyKit binary, builds ~/Applications/Muxy.app
```

Requires macOS 14+, Xcode 15+ command line tools. If Ghostty.app is
installed, its shell integration and terminfo are bundled into Muxy.

## Setup

1. **Agent status:** `./Scripts/install-claude-hook.sh` adds
   UserPromptSubmit/PreToolUse/Notification/Stop/StopFailure hooks to your
   Claude Code settings. They are a no-op outside Muxy and leave other
   hooks untouched; rerun it after updating Muxy.
2. **`muxy` on your PATH** (optional):
   `ln -s "$PWD/Scripts/muxy" ~/.local/bin/muxy`, then `muxy .` opens a
   session in the current directory. Folders dropped on the Dock icon do the
   same.

## Keys

| Key | Action |
| --- | --- |
| `⌘N` | new session (in home) |
| `⇧⌘N` | new window |
| `⌘T` | new tab in the current tab's directory |
| `⌘W` | close tab → the last tab closes the session → an empty window closes |
| `⌘1…9` · `⌃Tab` | switch tab |
| `⌃1…9` · `⌘⌥↑/↓` | switch session |
| `⌘J` | next session that wants you (any window) |
| `⌘K` | search sessions |
| `⌘B` | show/hide the sidebar (drag its edge to resize) |

Closing a window ends its sessions (confirmed if something runs); `⌘Q`
confirms too. Muxy keeps running without windows — click the Dock icon.

## Architecture notes

- SwiftUI + AppKit shell around `libghostty` (via
  [libghostty-spm](https://github.com/Lakr233/libghostty-spm), vendored and
  pinned under `Vendor/` with two small patches marked `muxy patch`; the
  ~50 MB GhosttyKit binary is fetched at build time, checksum-verified).
- Ghostty's exec backend spawns your login shell per tab — real PTY, real
  VT, no custom terminal code in this repo.
- The working directory (OSC 7) and command exit codes (OSC 133) come from
  the shell; repository, branch, PR and its checks are derived from them with
  `git` and `gh` (checks re-polled every minute).
- Chrome colors are parsed from your Ghostty theme files at launch and
  derived programmatically, so the UI always matches the terminal.

## Credits & license

MIT © Tristan Heitger. Muxy stands on
[Ghostty](https://ghostty.org) by Mitchell Hashimoto (MIT) and
[libghostty-spm](https://github.com/Lakr233/libghostty-spm) by
[@Lakr233](https://github.com/Lakr233) (MIT, license included under
`Vendor/`). Not affiliated with the Ghostty project.
