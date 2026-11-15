// A classic telephone ring ("ring-ring … ring-ring"), the same as the Mac app's:
// two mixed tones at 400 Hz and 450 Hz, 0.4 s on, 0.2 s off, 0.4 s on, 2 s off.

let context: AudioContext | undefined;
let timer: number | undefined;

function burst(ctx: AudioContext, start: number, duration: number) {
  const gain = ctx.createGain();
  gain.gain.setValueAtTime(0, start);
  gain.gain.linearRampToValueAtTime(0.25, start + 0.01);
  gain.gain.setValueAtTime(0.25, start + duration - 0.01);
  gain.gain.linearRampToValueAtTime(0, start + duration);
  gain.connect(ctx.destination);
  for (const frequency of [400, 450]) {
    const osc = ctx.createOscillator();
    osc.frequency.value = frequency;
    osc.connect(gain);
    osc.start(start);
    osc.stop(start + duration);
  }
}

function ringOnce() {
  if (!context) return;
  const t = context.currentTime + 0.05;
  burst(context, t, 0.4);
  burst(context, t + 0.6, 0.4);
}

export function startRingtone() {
  stopRingtone();
  context = new AudioContext();
  void context.resume();
  ringOnce();
  timer = window.setInterval(ringOnce, 3000);
}

export function stopRingtone() {
  if (timer !== undefined) window.clearInterval(timer);
  timer = undefined;
  void context?.close();
  context = undefined;
}
