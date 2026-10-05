# Muxy Remote — prototype

Clickable phone UI for driving Muxy remotely, with example data and no
connection to a Mac yet: the session list (Muxy's sidebar), Claude as chat
or as its terminal UI, shells as the real terminal look (IosevkaTerm,
Ghostty colors, the starship prompt) with tappable command blocks, and a
live grid for full-screen programs.

```sh
pnpm install
pnpm dev --host   # open http://<mac-ip>:5173 on the phone (same Wi-Fi)
```

Vite + React + Tailwind + shadcn. The bundled font is a subset of
IosevkaTerm Nerd Font (SIL Open Font License 1.1).
