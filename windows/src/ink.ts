// Drawing on a shared screen: a port of the Mac app's Ink.swift, using the same
// messages, so Mac and Windows teammates draw on each other's screens.
//
// Every shared screen has one board, identified by the sharer's user id. Positions are
// normalised (0…1 across the shared content, origin top-left). Ink is never part of the
// video: each computer draws it locally from these messages.

export type InkKind = "begin" | "points" | "end" | "cursor" | "leave" | "clear" | "info";

/** Wire format, identical to the Mac app's InkMessage (short keys keep messages small). */
export interface InkMessage {
  k: InkKind;
  /** Whose shared screen this is about. */
  b: string;
  s?: string;
  p?: number[][];
  /** Whether the stroke fades away by itself. */
  f?: boolean;
  /** Width / height of the shared content (sent by the sharer). */
  a?: number;
}

export const HOLD_BEFORE_FADE = 2.5;
export const FADE_DURATION = 0.7;
const KEEP_INK_KEY = "keepInk";

export const keepInk = {
  get: () => localStorage.getItem(KEEP_INK_KEY) === "1",
  set: (on: boolean) => localStorage.setItem(KEEP_INK_KEY, on ? "1" : "0"),
};

/** User ids from the Mac app arrive upper-case; everything here compares lower-case. */
export const norm = (id: string) => id.toLowerCase();

interface Stroke {
  id: string;
  user: string;
  points: { x: number; y: number }[];
  fade: boolean;
  endedAt?: number;
  lastUpdate: number;
}

export class InkBoard {
  strokes: Stroke[] = [];
  cursors = new Map<string, { x: number; y: number; seen: number }>();
  aspect?: number;
  onChange?: () => void;

  apply(message: InkMessage, fromUser: string) {
    const user = norm(fromUser);
    const now = performance.now() / 1000;
    const clamp = (v: number) => Math.min(Math.max(v, 0), 1);
    const points = (message.p ?? [])
      .filter((pair) => pair.length === 2)
      .map(([x, y]) => ({ x: clamp(x), y: clamp(y) }));
    const last = points[points.length - 1];

    switch (message.k) {
      case "begin":
        if (!message.s) return;
        this.strokes.push({ id: message.s, user, points, fade: message.f ?? true, lastUpdate: now });
        if (last) this.cursors.set(user, { ...last, seen: now });
        break;
      case "points": {
        const stroke = this.find(message.s, user);
        if (!stroke) return;
        stroke.points.push(...points);
        stroke.lastUpdate = now;
        if (last) this.cursors.set(user, { ...last, seen: now });
        break;
      }
      case "end": {
        const stroke = this.find(message.s, user);
        if (stroke) stroke.endedAt = now;
        break;
      }
      case "cursor":
        if (last) this.cursors.set(user, { ...last, seen: now });
        break;
      case "leave":
        this.cursors.delete(user);
        break;
      case "clear":
        this.strokes = [];
        break;
      case "info":
        if (message.a && message.a > 0) this.aspect = message.a;
        break;
    }
    this.onChange?.();
  }

  removeUser(user: string) {
    this.cursors.delete(norm(user));
    this.onChange?.();
  }

  reset() {
    this.strokes = [];
    this.cursors.clear();
    this.onChange?.();
  }

  opacity(stroke: Stroke, now: number) {
    if (!stroke.fade) return 1;
    // A stroke whose "end" never arrived (the drawer dropped) still fades.
    const end = stroke.endedAt ?? (now - stroke.lastUpdate > 5 ? stroke.lastUpdate : undefined);
    if (end === undefined) return 1;
    const age = now - end - HOLD_BEFORE_FADE;
    return age <= 0 ? 1 : Math.max(0, 1 - age / FADE_DURATION);
  }

  /** Drops finished fades and stale cursors. Returns true while something still animates. */
  tick(now = performance.now() / 1000) {
    this.strokes = this.strokes.filter((s) => !(s.fade && this.opacity(s, now) <= 0));
    for (const [user, cursor] of this.cursors) {
      if (now - cursor.seen >= 4) this.cursors.delete(user);
    }
    return this.strokes.some((s) => s.fade) || this.cursors.size > 0;
  }

  private find(id: string | undefined, user: string) {
    for (let i = this.strokes.length - 1; i >= 0; i--) {
      if (this.strokes[i].id === id && this.strokes[i].user === user) return this.strokes[i];
    }
    return undefined;
  }
}

export interface InkPeople {
  me: string;
  color: (user: string) => string;
  name: (user: string) => string;
}

// A pencil, tip at the bottom left, outlined in white so it shows on any screen.
const PENCIL_SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="26" height="26" viewBox="0 0 26 26">
<g stroke-linejoin="round" stroke-linecap="round">
<path d="M4 22 L5.6 16.4 L18.4 3.6 a2.3 2.3 0 0 1 3.3 0 l0.7 0.7 a2.3 2.3 0 0 1 0 3.3 L9.6 20.4 Z" fill="#111" stroke="#fff" stroke-width="2"/>
<path d="M16.2 5.8 L20.2 9.8" stroke="#fff" stroke-width="1.4" fill="none"/>
</g></svg>`;
const PENCIL_CURSOR = `url("data:image/svg+xml,${encodeURIComponent(PENCIL_SVG)}") 4 22, crosshair`;

/** Draws a board on a canvas and (when interactive) turns mouse drags into strokes. */
export class InkView {
  private _interactive = false;
  get interactive() {
    return this._interactive;
  }
  set interactive(on: boolean) {
    this._interactive = on;
    this.canvas.style.cursor = on ? PENCIL_CURSOR : "";
  }
  /** Viewer windows letterbox the video, so ink must follow the same fitted rectangle. */
  fitsAspect: boolean;
  fallbackAspect?: number;
  private frame = 0;
  private active?: string;
  private pending: { x: number; y: number }[] = [];
  private lastFlush = 0;
  private lastCursor = 0;

  constructor(
    private canvas: HTMLCanvasElement,
    public board: InkBoard,
    public boardID: string,
    public people: InkPeople,
    private send: (message: InkMessage) => void,
    fitsAspect: boolean,
  ) {
    this.fitsAspect = fitsAspect;
    board.onChange = () => this.schedule();
    new ResizeObserver(() => this.schedule()).observe(canvas);
    canvas.addEventListener("pointerdown", (e) => this.down(e));
    canvas.addEventListener("pointermove", (e) => this.move(e));
    canvas.addEventListener("pointerup", () => this.finish());
    canvas.addEventListener("pointercancel", () => this.finish());
    canvas.addEventListener("pointerleave", () => {
      if (this.interactive && !this.active) this.send({ k: "leave", b: this.boardID });
    });
  }

  attach(board: InkBoard, boardID: string) {
    this.finish();
    this.board = board;
    this.boardID = boardID;
    board.onChange = () => this.schedule();
    this.schedule();
  }

  /** Where the shared content sits inside the canvas, in CSS pixels. */
  private contentRect() {
    const w = this.canvas.clientWidth;
    const h = this.canvas.clientHeight;
    const aspect = this.board.aspect ?? this.fallbackAspect;
    if (!this.fitsAspect || !aspect || w === 0 || h === 0) return { x: 0, y: 0, w, h };
    let cw = w;
    let ch = w / aspect;
    if (ch > h) {
      ch = h;
      cw = h * aspect;
    }
    return { x: (w - cw) / 2, y: (h - ch) / 2, w: cw, h: ch };
  }

  private normalised(e: PointerEvent) {
    const rect = this.contentRect();
    const box = this.canvas.getBoundingClientRect();
    if (rect.w <= 0 || rect.h <= 0) return undefined;
    return { x: (e.clientX - box.left - rect.x) / rect.w, y: (e.clientY - box.top - rect.y) / rect.h };
  }

  schedule() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      const animating = this.board.tick();
      this.draw();
      if (animating) this.schedule();
    });
  }

  private draw() {
    const dpr = window.devicePixelRatio || 1;
    const w = this.canvas.clientWidth;
    const h = this.canvas.clientHeight;
    if (this.canvas.width !== Math.round(w * dpr) || this.canvas.height !== Math.round(h * dpr)) {
      this.canvas.width = Math.round(w * dpr);
      this.canvas.height = Math.round(h * dpr);
    }
    const ctx = this.canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    const rect = this.contentRect();
    const at = (p: { x: number; y: number }) => [rect.x + p.x * rect.w, rect.y + p.y * rect.h] as const;
    const now = performance.now() / 1000;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.lineWidth = Math.max(3, rect.w * 0.0035);

    for (const stroke of this.board.strokes) {
      const alpha = this.board.opacity(stroke, now);
      if (alpha <= 0 || stroke.points.length === 0) continue;
      ctx.globalAlpha = alpha;
      ctx.strokeStyle = this.people.color(stroke.user);
      ctx.beginPath();
      const [x0, y0] = at(stroke.points[0]);
      ctx.moveTo(x0, y0);
      if (stroke.points.length === 1) ctx.lineTo(x0 + 0.01, y0);
      for (const p of stroke.points.slice(1)) ctx.lineTo(...at(p));
      ctx.stroke();
    }
    ctx.globalAlpha = 1;

    for (const [user, cursor] of this.board.cursors) {
      if (user === norm(this.people.me)) continue;
      const [x, y] = at(cursor);
      this.drawCursor(ctx, x, y, this.people.color(user), this.people.name(user));
    }
  }

  private drawCursor(ctx: CanvasRenderingContext2D, x: number, y: number, color: string, name: string) {
    ctx.beginPath();
    ctx.moveTo(x, y);
    ctx.lineTo(x, y + 17);
    ctx.lineTo(x + 4.5, y + 13);
    ctx.lineTo(x + 12, y + 12.5);
    ctx.closePath();
    ctx.fillStyle = color;
    ctx.fill();
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = "white";
    ctx.stroke();

    const label = name.split(" ")[0] || name;
    ctx.font = "600 11px 'Segoe UI', system-ui, sans-serif";
    const width = ctx.measureText(label).width + 12;
    const tag = { x: x + 12, y: y + 16, w: width, h: 18 };
    ctx.beginPath();
    ctx.roundRect(tag.x, tag.y, tag.w, tag.h, 9);
    ctx.fillStyle = color;
    ctx.fill();
    ctx.fillStyle = "white";
    ctx.textBaseline = "middle";
    ctx.fillText(label, tag.x + 6, tag.y + tag.h / 2 + 0.5);
  }

  // Input

  private down(e: PointerEvent) {
    if (!this.interactive || e.button !== 0) return;
    const p = this.normalised(e);
    if (!p || p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return;
    this.canvas.setPointerCapture(e.pointerId);
    this.active = crypto.randomUUID().toUpperCase();
    this.pending = [];
    this.lastFlush = performance.now();
    this.send({ k: "begin", b: this.boardID, s: this.active, p: [[p.x, p.y]], f: !keepInk.get() });
  }

  private move(e: PointerEvent) {
    if (!this.interactive) return;
    const p = this.normalised(e);
    if (!p) return;
    if (this.active) {
      this.pending.push({ x: Math.min(Math.max(p.x, 0), 1), y: Math.min(Math.max(p.y, 0), 1) });
      // Batch points so a fast drag is a few dozen messages a second, not hundreds.
      if (performance.now() - this.lastFlush > 30) this.flush();
      return;
    }
    if (p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return;
    if (performance.now() - this.lastCursor < 35) return;
    this.lastCursor = performance.now();
    this.send({ k: "cursor", b: this.boardID, p: [[p.x, p.y]] });
  }

  private flush() {
    if (!this.active || this.pending.length === 0) return;
    this.send({ k: "points", b: this.boardID, s: this.active, p: this.pending.map((p) => [p.x, p.y]) });
    this.pending = [];
    this.lastFlush = performance.now();
  }

  finish() {
    if (!this.active) return;
    this.flush();
    this.send({ k: "end", b: this.boardID, s: this.active });
    this.active = undefined;
  }
}
