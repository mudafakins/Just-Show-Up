// In-app updates from the project's GitHub Releases (Tauri's updater plugin).
// A release made with scripts/release.sh carries a signed installer and latest.json;
// the app only installs updates signed with the key in tauri.conf.json.
import { getVersion } from "@tauri-apps/api/app";
import { relaunch } from "@tauri-apps/plugin-process";
import { check, type Update } from "@tauri-apps/plugin-updater";

export const update = {
  current: "",
  available: undefined as Update | undefined,
  /** Called after a check or install step; a message goes in the panel's notice line. */
  onChange: (_message?: string) => {},
};

let busy = false;

const AUTO_KEY = "autoUpdate";
/** Install new versions without asking (on by default), when nothing is going on. */
export const autoUpdate = {
  get: () => localStorage.getItem(AUTO_KEY) !== "0",
  set: (on: boolean) => localStorage.setItem(AUTO_KEY, on ? "1" : "0"),
};

/** Installs a waiting update when updating automatically and `isIdle` says nothing is going on. */
export async function installIfIdle(isIdle: () => boolean) {
  if (autoUpdate.get() && update.available && !busy && isIdle()) await installUpdate();
}
export const updateBusy = () => busy;

void getVersion().then((v) => {
  update.current = v;
  update.onChange();
});

export async function checkForUpdate(userInitiated: boolean) {
  if (busy) return;
  busy = true;
  try {
    const found = await check();
    update.available = found ?? undefined;
    if (userInitiated) {
      update.onChange(
        found ? `Version ${found.version} is ready. Choose Update in settings.` : `You're on the latest version (${update.current}).`,
      );
    } else {
      update.onChange();
    }
  } catch {
    // No release yet, or offline.
    if (userInitiated) update.onChange("Couldn't check for updates. Check your internet connection.");
  } finally {
    busy = false;
  }
}

export async function installUpdate() {
  const found = update.available;
  if (!found || busy) return;
  busy = true;
  update.onChange(`Downloading version ${found.version}…`);
  try {
    // On Windows the installer closes the app, installs, and opens it again.
    await found.downloadAndInstall();
    await relaunch();
  } catch (e) {
    busy = false;
    update.onChange(`Update failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}
