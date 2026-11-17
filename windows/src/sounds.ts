// Small, soft chimes for room events, the same as the Mac app's Sounds.swift:
// rising notes for a join, falling notes for a leave; quieter when it's a teammate.

export type Cue =
  | "join"
  | "leave"
  | "teammateJoined"
  | "teammateLeft"
  | "shareStarted"
  | "shareStopped"
  | "teammateShareStarted"
  | "teammateShareStopped";

const KEY = "playSounds";
export const sounds = {
  enabled: () => localStorage.getItem(KEY) !== "0",
  setEnabled: (on: boolean) => localStorage.setItem(KEY, on ? "1" : "0"),
};

let context: AudioContext | undefined;

export function playSound(cue: Cue) {
  if (!sounds.enabled()) return;
  context ??= new AudioContext();
  const ctx = context;
  void ctx.resume();
  const low = 783.99; // G5
  const high = 1046.5; // C6
  // Rooms: two notes. Sharing: a quicker, brighter three-note run (E6, G#6, B6).
  const share = cue.toLowerCase().includes("share");
  const run = share ? [1318.5, 1661.2, 1975.5] : [low, high];
  const rising = cue === "join" || cue === "teammateJoined" || cue === "shareStarted" || cue === "teammateShareStarted";
  const notes = rising ? run : [...run].reverse();
  const step = share ? 0.065 : 0.11;
  const ring = share ? 0.24 : 0.32;
  const volume = cue.startsWith("teammate") ? 0.08 : 0.14;
  const start = ctx.currentTime + 0.02;
  notes.forEach((frequency, n) => {
    const t = start + n * step;
    const gain = ctx.createGain();
    gain.gain.setValueAtTime(0, t);
    gain.gain.linearRampToValueAtTime(volume, t + 0.006);
    gain.gain.exponentialRampToValueAtTime(0.0001, t + ring);
    gain.connect(ctx.destination);
    // A touch of the octave makes it bell-like rather than a beep.
    for (const [mult, level] of [[1, 1], [2, 0.25]]) {
      const osc = ctx.createOscillator();
      const g = ctx.createGain();
      g.gain.value = level;
      osc.frequency.value = frequency * mult;
      osc.connect(g).connect(gain);
      osc.start(t);
      osc.stop(t + ring + 0.02);
    }
  });
}
