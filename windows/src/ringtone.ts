// The sound for an incoming call, the same choices as the Mac app's Ringtone.swift:
// the sound clips in Ringtones/ (bundled into the app), then simple generated tones.
// Each person picks their own in Settings → Ringtone.

const TONES = [
  { id: "classic", title: "Classic Phone" },
  { id: "marimba", title: "Marimba" },
  { id: "chime", title: "Chime" },
  { id: "digital", title: "Digital" },
  { id: "gentle", title: "Gentle" },
] as const;
type ToneID = (typeof TONES)[number]["id"];

export type Ringtone = { id: string; title: string; url?: string; tone?: ToneID };

// "01 - Title.mp3" → id "clip:01 - Title", shown as "Title" (same ids as the Mac).
const clipFiles = import.meta.glob("../../Ringtones/*.mp3", { eager: true, query: "?url", import: "default" }) as Record<
  string,
  string
>;
export const CLIPS: Ringtone[] = Object.entries(clipFiles)
  .map(([path, url]) => {
    const name = decodeURIComponent(path.split("/").pop()!.replace(/\.mp3$/i, ""));
    return { id: `clip:${name}`, title: name.replace(/^\d+\s*-\s*/, ""), url };
  })
  .sort((a, b) => a.id.localeCompare(b.id, undefined, { numeric: true }));
export const TONE_CHOICES: Ringtone[] = TONES.map((t) => ({ id: t.id, title: t.title, tone: t.id }));
export const RINGTONES: Ringtone[] = [...CLIPS, ...TONE_CHOICES];

const KEY = "ringtone";
const defaultID = () => CLIPS[0]?.id ?? "classic";
export const ringtone = {
  get: (): Ringtone => {
    const saved = localStorage.getItem(KEY) ?? defaultID();
    return RINGTONES.find((r) => r.id === saved) ?? RINGTONES.find((r) => r.id === defaultID()) ?? TONE_CHOICES[0];
  },
  set: (id: string) => localStorage.setItem(KEY, id),
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
function cycle(ctx: AudioContext, id: ToneID): number {
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

let clip: HTMLAudioElement | undefined;
let clipTimer: number | undefined;
let preview: HTMLAudioElement | undefined;
let pendingPreview: number | undefined;

export function startRingtone() {
  stopRingtone();
  stopPreview();
  const choice = ringtone.get();
  if (choice.url) {
    // Play the clip, pause a moment, play it again: back to back, short clips
    // would blur into one long noise.
    const audio = new Audio(choice.url);
    audio.volume = 0.8;
    audio.addEventListener("ended", () => {
      clipTimer = window.setTimeout(() => {
        if (clip === audio) void audio.play().catch(() => {});
      }, 1200);
    });
    clip = audio;
    void audio.play().catch(() => {});
    return;
  }
  const ctx = new AudioContext();
  context = ctx;
  void ctx.resume();
  const seconds = cycle(ctx, choice.tone!);
  timer = window.setInterval(() => cycle(ctx, choice.tone!), seconds * 1000);
}

export function stopRingtone() {
  if (timer !== undefined) window.clearInterval(timer);
  timer = undefined;
  void context?.close();
  context = undefined;
  if (clipTimer !== undefined) window.clearTimeout(clipTimer);
  clipTimer = undefined;
  clip?.pause();
  clip = undefined;
}

/** Plays a ringtone once, for choosing one in Settings. Waits a moment first, so
 *  sweeping the pointer down the list stays quiet. */
export function previewRingtone(id: string) {
  stopPreview();
  if (context || clip) return; // a real call is ringing
  const choice = RINGTONES.find((r) => r.id === id);
  if (!choice) return;
  pendingPreview = window.setTimeout(() => {
    if (choice.url) {
      preview = new Audio(choice.url);
      preview.volume = 0.8;
      void preview.play().catch(() => {});
    } else {
      previewContext = new AudioContext();
      void previewContext.resume();
      cycle(previewContext, choice.tone!);
    }
  }, 150);
}

export function stopPreview() {
  if (pendingPreview !== undefined) window.clearTimeout(pendingPreview);
  pendingPreview = undefined;
  preview?.pause();
  preview = undefined;
  void previewContext?.close();
  previewContext = undefined;
}

// ---------------------------------------------------------------- soundboard

let board: HTMLAudioElement | undefined;
let boardStarted = 0;

/** Plays a soundboard clip once; one at a time, so rapid clicks don't pile up. */
export function playClip(id: string) {
  const clip = CLIPS.find((c) => c.id === id);
  if (!clip?.url || Date.now() - boardStarted < 250) return;
  boardStarted = Date.now();
  board?.pause();
  board = new Audio(clip.url);
  board.volume = 0.8;
  void board.play().catch(() => {});
}

export function stopClip() {
  board?.pause();
  board = undefined;
}

const EMOJI: [string, string][] = [
  ["title theme", "🎬"], ["intro", "🎺"], ["hey hey", "👋"], ["laugh", "😂"],
  ["aaiye", "🙏"], ["dramatic", "😱"], ["yes", "🙌"], ["turr", "💨"],
  ["flute", "🎶"], ["nahi", "🙅"], ["uhh", "😩"], ["haaa", "😮"],
  ["tabla", "🥁"], ["uii", "😵"], ["soap", "📺"], ["funny", "🤪"], ["locha", "🤯"],
];
/** A picture for each clip's tile, from its name ("Hey Hey 3" → 👋). Same as the Mac. */
export const clipEmoji = (title: string) => EMOJI.find(([k]) => title.toLowerCase().includes(k))?.[1] ?? "🔊";
