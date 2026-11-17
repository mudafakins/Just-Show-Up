// The sound for an incoming call, the same choices as the Mac app's Ringtone.swift.
// Each person picks their own in Settings → Ringtone.

export const RINGTONES = [
  { id: "classic", title: "Classic Phone" },
  { id: "marimba", title: "Marimba" },
  { id: "chime", title: "Chime" },
  { id: "digital", title: "Digital" },
  { id: "gentle", title: "Gentle" },
] as const;
export type RingtoneID = (typeof RINGTONES)[number]["id"];

const KEY = "ringtone";
export const ringtone = {
  get: (): RingtoneID => (RINGTONES.find((r) => r.id === localStorage.getItem(KEY))?.id ?? "classic"),
  set: (id: RingtoneID) => localStorage.setItem(KEY, id),
};

let context: AudioContext | undefined;
let timer: number | undefined;
let previewContext: AudioContext | undefined;

/** A steady tone with short fades (no clicks). */
function tone(ctx: AudioContext, start: number, duration: number, frequencies: number[], level: number) {
  const gain = ctx.createGain();
  gain.gain.setValueAtTime(0, start);
  gain.gain.linearRampToValueAtTime(level, start + 0.01);
  gain.gain.setValueAtTime(level, start + duration - 0.01);
  gain.gain.linearRampToValueAtTime(0, start + duration);
  gain.connect(ctx.destination);
  for (const frequency of frequencies) {
    const osc = ctx.createOscillator();
    osc.frequency.value = frequency;
    osc.connect(gain);
    osc.start(start);
    osc.stop(start + duration);
  }
}

/** A struck note: instant attack, smooth decay, a little overtone. */
function mallet(ctx: AudioContext, start: number, frequency: number, decay: number, level: number) {
  const length = Math.min(1.2, 5 / decay);
  const gain = ctx.createGain();
  gain.gain.setValueAtTime(0, start);
  gain.gain.linearRampToValueAtTime(level, start + 0.003);
  gain.gain.exponentialRampToValueAtTime(0.0001, start + length);
  gain.connect(ctx.destination);
  for (const [mult, amount] of [[1, 1], [4, 0.15]]) {
    const osc = ctx.createOscillator();
    const g = ctx.createGain();
    g.gain.value = amount;
    osc.frequency.value = frequency * mult;
    osc.connect(g).connect(gain);
    osc.start(start);
    osc.stop(start + length);
  }
}

/** Plays one cycle; returns how long a cycle lasts (seconds). */
function cycle(ctx: AudioContext, id: RingtoneID): number {
  const t = ctx.currentTime + 0.05;
  switch (id) {
    case "classic":
      tone(ctx, t, 0.4, [400, 450], 0.25);
      tone(ctx, t + 0.6, 0.4, [400, 450], 0.25);
      return 3.0;
    case "marimba": {
      const phrase = [523.25, 659.25, 783.99, 1046.5, 783.99, 1046.5];
      for (const offset of [0, 0.95]) phrase.forEach((f, n) => mallet(ctx, t + offset + n * 0.13, f, 7, 0.35));
      return 3.0;
    }
    case "chime":
      [1318.5, 1046.5, 1318.5, 1046.5].forEach((f, n) => mallet(ctx, t + n * 0.38, f, 3.2, 0.28));
      return 3.2;
    case "digital":
      for (let n = 0; n < 3; n++) for (let k = 0; k < 2; k++) tone(ctx, t + n * 0.36 + k * 0.12, 0.08, [1400], 0.2);
      return 2.6;
    case "gentle":
      [587.33, 739.99, 880, 739.99].forEach((f, n) => mallet(ctx, t + n * 0.42, f, 2.4, 0.22));
      return 3.6;
  }
}

export function startRingtone() {
  stopRingtone();
  const ctx = new AudioContext();
  context = ctx;
  void ctx.resume();
  const id = ringtone.get();
  const seconds = cycle(ctx, id);
  timer = window.setInterval(() => cycle(ctx, id), seconds * 1000);
}

export function stopRingtone() {
  if (timer !== undefined) window.clearInterval(timer);
  timer = undefined;
  void context?.close();
  context = undefined;
}

/** One cycle of a ringtone, for choosing one in Settings. */
export function previewRingtone(id: RingtoneID) {
  if (context) return; // a real call is ringing
  void previewContext?.close();
  previewContext = new AudioContext();
  void previewContext.resume();
  cycle(previewContext, id);
}
