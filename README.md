# Muxy

A native macOS terminal workspace for running many coding agents (Claude
Code, Codex, …) in parallel — **real Ghostty rendering**, a sidebar of open
workspaces, Chrome-style tabs, and notifications the moment an agent needs
you. One window instead of window chaos, built to stay fast.

- **It IS your Ghostty.** Muxy embeds [libghostty](https://ghostty.org) and
  loads your own `~/.config/ghostty/config` — theme, font, opacity, padding,
  everything, 1:1. Light/dark follows the system.
- **cmux-style model.** Sidebar items are open workspaces (a git worktree or
  an ad-hoc terminal); each owns its tabs. Close it and it's gone.
- **Agent-aware.** Every terminal carries a session id; a Claude Code hook
  reports "done / needs input" back to Muxy deterministically → orange dot
  on the tab and sidebar item, plus a macOS banner ("Claude wartet auf
  dich") with sound when Muxy is in the background.
- **Built to stay fast.** Exactly one terminal surface is ever attached to
  the view hierarchy; background sessions keep their PTY and state but cost
  no rendering. No session restore at launch, scrollback capped, one
  process. (Idle: ~85 MB RAM, 0% CPU.)

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

Requires macOS 14+, Xcode 15+ command line tools.

## Setup

1. **Projects:** list your repos in `~/.config/muxy/projects.txt` (one
   absolute path per line, `~` allowed). They appear — with all their git
   worktrees — in the menu-bar "Öffnen" menu.
2. **Claude notifications:** `./Scripts/install-claude-hook.sh` adds a
   Stop/Notification hook to your Claude Code settings. The hook is a no-op
   outside Muxy and leaves existing hooks untouched.

## Use

| Key | Action |
| --- | --- |
| `⌘N` | new terminal workspace (sidebar item) |
| `⇧⌘N` | create a git worktree (`<repo>.worktrees/<branch>`) + open it |
| `⌘T` | new tab in the current workspace |
| `⌘W` | close tab → last tab closes the workspace → nothing left quits Muxy (confirms only if something is actually running — Ghostty's own check) |
| `⌘1..9` | switch tab |
| hover ✕ / right-click | close a sidebar item |

Orange is the only signal color: a dot means an agent wants you; opening the
session clears it.

## Architecture notes

- SwiftUI + AppKit shell around `libghostty` (via
  [libghostty-spm](https://github.com/Lakr233/libghostty-spm), vendored and
  pinned under `Vendor/` with two small patches marked `muxy patch`; the
  ~50 MB GhosttyKit binary is fetched at build time, checksum-verified).
- Ghostty's exec backend spawns your login shell per tab — real PTY, real
  VT, no custom terminal code in this repo.
- Chrome colors are parsed from your Ghostty theme files at launch and
  derived programmatically, so the UI always matches the terminal.
- Anti-lag rules were derived from
  [cmux issue #4101](https://github.com/manaflow-ai/cmux/issues/4101);
  see `Sources/muxy/TerminalSession.swift`.

## Credits & license

MIT © Tristan Heitger. Muxy stands on
[Ghostty](https://ghostty.org) by Mitchell Hashimoto (MIT) and
[libghostty-spm](https://github.com/Lakr233/libghostty-spm) by
[@Lakr233](https://github.com/Lakr233) (MIT, license included under
`Vendor/`). Not affiliated with the Ghostty project.
