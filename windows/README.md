# Just Show Up! for Windows

The Windows version of the menu bar app: a tray icon with the same panel, the same
team, Rooms 1–3, calling with a phone ring, voice, screen sharing and drawing on
screens. It talks to the same Supabase project and LiveKit rooms as the Mac app, so
Mac and Windows teammates are on one team.

Built with [Tauri](https://tauri.app): a small Rust shell (`src-tauri/`) that owns the
tray and windows, and the app itself in TypeScript (`src/`), which mirrors the Mac
app's `TeamStore.swift`, `CallEngine.swift` and `Ink.swift`.

## Getting the installer

The latest release has it: **Releases → latest → `…x64-setup.exe`** (the Mac app is
`JustShowUp-mac.zip` on the same page). Installed apps update themselves: when a new
release is out, the settings gear gets a dot and offers **Update to …**.

To release a new version (both apps), run on the Mac: `scripts/release.sh 0.3.0`.
GitHub adds the Windows files to the release about 10 minutes later.

Every push that changes this folder also builds a test installer:
**Actions → Windows build → the run → Artifacts**. The repository needs three
secrets: `SUPABASE_URL` and `SUPABASE_KEY` (the values in `Config.local.json`) and
`TAURI_SIGNING_PRIVATE_KEY` (the update key, `~/.tauri/justshowup-updater.key` on the
Mac that made it; keep a backup, since without it you can't ship Windows updates).

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
