# Just Show Up! for Windows

The Windows version of the menu bar app: a tray icon with the same panel, the same
team, Rooms 1–3, calling with a phone ring, voice, screen sharing and drawing on
screens. It talks to the same Supabase project and LiveKit rooms as the Mac app, so
Mac and Windows teammates are on one team.

Built with [Tauri](https://tauri.app): a small Rust shell (`src-tauri/`) that owns the
tray and windows, and the app itself in TypeScript (`src/`), which mirrors the Mac
app's `TeamStore.swift`, `CallEngine.swift` and `Ink.swift`.

## Getting the installer

Every push that changes this folder builds an installer on GitHub:
**Actions → Windows build → latest run → Artifacts → JustShowUp-Windows-installer**.
The repository needs two secrets, `SUPABASE_URL` and `SUPABASE_KEY`, with the same
values as `Config.local.json`.

## Building locally

Needs Node.js and Rust. Write `.env.local` here:

```
VITE_SUPABASE_URL=https://<project>.supabase.co
VITE_SUPABASE_KEY=<publishable key>
```

then `npm install` and `npx tauri build` (on Windows) or `npx tauri dev` (any OS,
for trying it out).

## Differences from the Mac app

- Sharing uses Windows' own screen picker.
- Drawings appear on your own screen when you share an **entire screen**. When you
  share a single window, teammates can still draw on it, but only they see the ink.
