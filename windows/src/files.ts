// Sending files straight to a teammate, computer to computer, over WebRTC. The same
// protocol as the Mac app (Sources/TeamPointer/FileTransfer.swift):
//
//   offer (name, size) → accept / decline → sdp offer/answer + ice → data channel:
//   64 KB binary pieces, then {"t":"end","sha256":…} → receiver checks → {"t":"ok"}.
//
// Disk work (reading, writing, zipping, fingerprints) happens in Rust (src-tauri/src/files.rs).

import { invoke } from "@tauri-apps/api/core";

export interface FileSignal {
  kind: "offer" | "accept" | "decline" | "cancel" | "sdp" | "ice";
  id: string;
  from: string;
  to: string;
  name?: string;
  fileName?: string;
  size?: number;
  sdpType?: "offer" | "answer";
  sdp?: string;
  ice?: { candidate: string; sdpMid: string | null; sdpMLineIndex: number };
  reason?: string;
}

export interface Transfer {
  id: string;
  teammate: string;
  teammateName: string;
  direction: "sending" | "receiving";
  fileName: string;
  size: number;
  stage: "waiting" | "connecting" | "transferring" | "checking";
  sent: number;
  speed: number;
}

const CHUNK = 64 * 1024;
const READ = 1024 * 1024;
const HIGH_WATER = 4 * 1024 * 1024;
const STUN: RTCIceServer[] = [{ urls: ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"] }];

const norm = (id: string) => id.toLowerCase();

interface Link {
  pc: RTCPeerConnection;
  channel?: RTCDataChannel;
  pendingIce: RTCIceCandidateInit[];
  closed: boolean;
}

export const files = {
  active: [] as Transfer[],
  lastSaved: undefined as string | undefined,

  // Wired up by main.ts.
  sendSignal: async (_signal: FileSignal) => {},
  myID: () => undefined as string | undefined,
  myName: () => "",
  isBusy: () => false,
  onMessage: (_text: string) => {},
  onChange: () => {},
  iceServers: async (): Promise<RTCIceServer[]> => STUN,

  incoming(): Transfer[] {
    return this.active.filter((t) => t.direction === "receiving" && t.stage === "waiting");
  },
  transferWith(teammate: string): Transfer | undefined {
    return this.active.find(
      (t) => t.teammate === norm(teammate) && !(t.direction === "receiving" && t.stage === "waiting"),
    );
  },
};

const links = new Map<string, Link>();
const outgoing = new Map<string, { path: string; temporary: boolean }>();
const timers = new Map<string, number>();
const samples = new Map<string, { time: number; bytes: number }>();

function find(id: string) {
  return files.active.find((t) => t.id === id);
}
function update(id: string, change: (t: Transfer) => void) {
  const t = find(id);
  if (t) {
    change(t);
    files.onChange();
  }
}

function expire(id: string, seconds: number, message?: string) {
  window.clearTimeout(timers.get(id));
  timers.set(
    id,
    window.setTimeout(() => {
      if (!find(id)) return;
      if (message) files.onMessage(message);
      cancel(id);
    }, seconds * 1000),
  );
}

function finish(id: string) {
  window.clearTimeout(timers.get(id));
  timers.delete(id);
  const link = links.get(id);
  if (link) {
    link.closed = true;
    link.channel?.close();
    link.pc.close();
    links.delete(id);
  }
  const out = outgoing.get(id);
  if (out?.temporary) void invoke("remove_temporary", { path: out.path });
  outgoing.delete(id);
  samples.delete(id);
  const t = find(id);
  if (t?.direction === "receiving") void invoke("recv_abort", { id });
  files.active = files.active.filter((x) => x.id !== id);
  files.onChange();
}

function progress(id: string, bytes: number) {
  const now = performance.now();
  update(id, (t) => {
    const last = samples.get(id);
    if (!last) samples.set(id, { time: now, bytes });
    else if (now - last.time > 300) {
      const rate = ((bytes - last.bytes) * 1000) / (now - last.time);
      t.speed = t.speed === 0 ? rate : t.speed * 0.6 + rate * 0.4;
      samples.set(id, { time: now, bytes });
    }
    t.sent = bytes;
  });
}

const uuid = () => crypto.randomUUID().toLowerCase();

// ---------------------------------------------------------------- sending

/** Offers files to a teammate. Several files, or a folder, go as one zip. */
export async function sendFiles(paths: string[], teammate: { id: string; name: string }) {
  const me = files.myID();
  if (!me || !paths.length) return;
  if (files.transferWith(teammate.id)) {
    files.onMessage(`Already sending to ${teammate.name}. Wait for it to finish.`);
    return;
  }
  let prepared: { path: string; name: string; size: number; temporary: boolean };
  try {
    prepared = await invoke("prepare_send", { paths, sender: files.myName() });
  } catch (e) {
    files.onMessage(`Couldn't prepare the file: ${e}`);
    return;
  }
  const id = uuid();
  outgoing.set(id, { path: prepared.path, temporary: prepared.temporary });
  files.active.push({
    id,
    teammate: norm(teammate.id),
    teammateName: teammate.name,
    direction: "sending",
    fileName: prepared.name,
    size: prepared.size,
    stage: "waiting",
    sent: 0,
    speed: 0,
  });
  files.onChange();
  await files.sendSignal({ kind: "offer", id, from: me, to: norm(teammate.id), name: files.myName(), fileName: prepared.name, size: prepared.size });
  expire(id, 90, `${teammate.name} didn't answer. The file wasn't sent.`);
}

/** Stops a transfer (either direction) and tells the other side. */
export function cancel(id: string) {
  const t = find(id);
  const me = files.myID();
  if (!t || !me) return;
  void files.sendSignal({ kind: "cancel", id, from: me, to: t.teammate });
  finish(id);
}

export function accept(id: string) {
  const t = find(id);
  const me = files.myID();
  if (!t || !me) return;
  update(id, (x) => (x.stage = "connecting"));
  expire(id, 60, `Couldn't connect to ${t.teammateName}. The file wasn't received.`);
  void files.sendSignal({ kind: "accept", id, from: me, to: t.teammate });
}

export function decline(id: string) {
  const t = find(id);
  const me = files.myID();
  if (!t || !me) return;
  void files.sendSignal({ kind: "decline", id, from: me, to: t.teammate });
  finish(id);
}

// ---------------------------------------------------------------- signals

export function receiveSignal(signal: FileSignal) {
  const me = files.myID();
  if (!me || norm(signal.to) !== me) return;
  const from = norm(signal.from);
  const t = find(signal.id);
  // Only the person on the other end of this transfer may steer it.
  if (t && t.teammate !== from) return;

  switch (signal.kind) {
    case "offer": {
      if (t || !signal.fileName || signal.size === undefined) return;
      if (files.isBusy()) {
        void files.sendSignal({ kind: "decline", id: signal.id, from: me, to: from, reason: "busy" });
        return;
      }
      files.active.push({
        id: signal.id,
        teammate: from,
        teammateName: signal.name ?? "A teammate",
        direction: "receiving",
        fileName: signal.fileName,
        size: signal.size,
        stage: "waiting",
        sent: 0,
        speed: 0,
      });
      files.onChange();
      expire(signal.id, 90);
      break;
    }
    case "accept": {
      const out = outgoing.get(signal.id);
      if (!t || t.direction !== "sending" || t.stage !== "waiting" || !out) return;
      update(signal.id, (x) => (x.stage = "connecting"));
      expire(signal.id, 45, `Couldn't connect to ${t.teammateName} directly. Try again, or from another network.`);
      void startSending(t, out.path);
      break;
    }
    case "decline":
      if (!t) return;
      files.onMessage(
        signal.reason === "busy"
          ? `${t.teammateName} is on Do Not Disturb. The file wasn't sent.`
          : `${t.teammateName} declined ${t.fileName}.`,
      );
      finish(signal.id);
      break;
    case "cancel":
      if (!t) return;
      files.onMessage(
        t.direction === "receiving"
          ? `${t.teammateName} stopped sending ${t.fileName}.`
          : `${t.teammateName} stopped receiving ${t.fileName}.`,
      );
      finish(signal.id);
      break;
    case "sdp":
      if (!t || !signal.sdp) return;
      if (signal.sdpType === "offer" && t.direction === "receiving" && t.stage === "connecting") {
        void startReceiving(t, signal.sdp);
      } else if (signal.sdpType === "answer") {
        const link = links.get(signal.id);
        void link?.pc.setRemoteDescription({ type: "answer", sdp: signal.sdp }).then(() => flushIce(link)).catch(() => failed(t));
      }
      break;
    case "ice": {
      const link = links.get(signal.id);
      if (!link || !signal.ice) return;
      const candidate: RTCIceCandidateInit = {
        candidate: signal.ice.candidate,
        sdpMid: signal.ice.sdpMid,
        sdpMLineIndex: signal.ice.sdpMLineIndex,
      };
      if (link.pc.remoteDescription) void link.pc.addIceCandidate(candidate).catch(() => {});
      else link.pendingIce.push(candidate);
      break;
    }
  }
}

function flushIce(link: Link) {
  for (const c of link.pendingIce.splice(0)) void link.pc.addIceCandidate(c).catch(() => {});
}

// ---------------------------------------------------------------- connections

async function newLink(t: Transfer): Promise<Link> {
  const me = files.myID()!;
  const pc = new RTCPeerConnection({ iceServers: await files.iceServers() });
  const link: Link = { pc, pendingIce: [], closed: false };
  links.set(t.id, link);
  pc.onicecandidate = (e) => {
    if (!e.candidate) return;
    void files.sendSignal({
      kind: "ice",
      id: t.id,
      from: me,
      to: t.teammate,
      ice: { candidate: e.candidate.candidate, sdpMid: e.candidate.sdpMid, sdpMLineIndex: e.candidate.sdpMLineIndex ?? 0 },
    });
  };
  pc.oniceconnectionstatechange = () => {
    if (pc.iceConnectionState === "failed") failed(t);
  };
  return link;
}

function failed(t: Transfer) {
  if (!find(t.id)) return;
  files.onMessage(`Lost the connection to ${t.teammateName}. ${t.fileName} wasn't finished.`);
  cancel(t.id);
}

function opened(t: Transfer) {
  window.clearTimeout(timers.get(t.id));
  update(t.id, (x) => (x.stage = "transferring"));
}

async function startSending(t: Transfer, path: string) {
  const me = files.myID()!;
  const link = await newLink(t);
  const channel = link.pc.createDataChannel("file", { ordered: true });
  channel.binaryType = "arraybuffer";
  channel.bufferedAmountLowThreshold = HIGH_WATER / 2;
  link.channel = channel;
  channel.onopen = () => {
    opened(t);
    void pump(t, link, channel, path);
  };
  channel.onclose = () => {
    if (!link.closed) failed(t);
  };
  channel.onmessage = (e) => {
    if (typeof e.data !== "string") return;
    const message = JSON.parse(e.data) as { t: string };
    if (message.t === "ok" || message.t === "bad") {
      files.onMessage(
        message.t === "ok"
          ? `Sent ${t.fileName} to ${t.teammateName}.`
          : `${t.fileName} didn't arrive intact. Try sending it again.`,
      );
      finish(t.id);
    }
  };
  try {
    const offer = await link.pc.createOffer();
    await link.pc.setLocalDescription(offer);
    await files.sendSignal({ kind: "sdp", id: t.id, from: me, to: t.teammate, sdpType: "offer", sdp: offer.sdp });
  } catch {
    failed(t);
  }
}

async function pump(t: Transfer, link: Link, channel: RTCDataChannel, path: string) {
  let offset = 0;
  let lastReport = 0;
  try {
    while (!link.closed && offset < t.size) {
      const piece = new Uint8Array(
        await invoke<ArrayBuffer>("read_chunk", { path, offset, length: Math.min(READ, t.size - offset) }),
      );
      if (!piece.length) break;
      for (let i = 0; i < piece.length && !link.closed; i += CHUNK) {
        if (channel.bufferedAmount > HIGH_WATER) {
          await new Promise<void>((resolve) => {
            channel.onbufferedamountlow = () => resolve();
          });
        }
        channel.send(piece.subarray(i, Math.min(i + CHUNK, piece.length)));
      }
      offset += piece.length;
      if (performance.now() - lastReport > 100) {
        lastReport = performance.now();
        progress(t.id, offset);
      }
    }
    if (link.closed) return;
    progress(t.id, offset);
    const sha256 = await invoke<string>("file_sha256", { path });
    channel.send(JSON.stringify({ t: "end", size: offset, sha256 }));
  } catch {
    failed(t);
  }
}

async function startReceiving(t: Transfer, offer: string) {
  if (links.has(t.id)) return;
  const me = files.myID()!;
  try {
    await invoke("recv_begin", { id: t.id });
  } catch (e) {
    files.onMessage(`Couldn't save to Downloads: ${e}`);
    cancel(t.id);
    return;
  }
  const link = await newLink(t);
  let received = 0;
  let pending: Uint8Array[] = [];
  let pendingBytes = 0;
  // Writes go to disk in order, about 1 MB at a time.
  let writes: Promise<unknown> = Promise.resolve();
  const flush = () => {
    if (!pendingBytes) return;
    const bytes = new Uint8Array(pendingBytes);
    let at = 0;
    for (const p of pending) {
      bytes.set(p, at);
      at += p.length;
    }
    pending = [];
    pendingBytes = 0;
    writes = writes.then(() => invoke("recv_write", bytes, { headers: { "x-id": t.id } })).catch(() => failed(t));
  };

  link.pc.ondatachannel = (e) => {
    const channel = e.channel;
    channel.binaryType = "arraybuffer";
    link.channel = channel;
    channel.onopen = () => opened(t);
    if (channel.readyState === "open") opened(t);
    channel.onclose = () => {
      if (!link.closed) failed(t);
    };
    channel.onmessage = (m) => {
      if (link.closed) return;
      if (typeof m.data !== "string") {
        const piece = new Uint8Array(m.data as ArrayBuffer);
        pending.push(piece);
        pendingBytes += piece.length;
        received += piece.length;
        if (pendingBytes >= READ) flush();
        progress(t.id, received);
        return;
      }
      const message = JSON.parse(m.data) as { t: string; sha256?: string };
      if (message.t !== "end") return;
      flush();
      update(t.id, (x) => (x.stage = "checking"));
      void writes.then(async () => {
        let saved: string | null = null;
        try {
          saved = await invoke<string | null>("recv_finish", { id: t.id, name: t.fileName, size: t.size, sha256: message.sha256 ?? "" });
        } catch {
          saved = null;
        }
        if (channel.readyState === "open") channel.send(JSON.stringify({ t: saved ? "ok" : "bad" }));
        if (saved) {
          files.lastSaved = saved;
          files.onMessage(`Saved ${saved.split(/[\\/]/).pop()} from ${t.teammateName}.`);
        } else {
          files.onMessage(`${t.fileName} from ${t.teammateName} didn't arrive intact. Ask them to send it again.`);
        }
        // The part file is already gone or renamed; don't abort it.
        files.active = files.active.filter((x) => x.id !== t.id);
        finish(t.id);
      });
    };
  };

  try {
    await link.pc.setRemoteDescription({ type: "offer", sdp: offer });
    flushIce(link);
    const answer = await link.pc.createAnswer();
    await link.pc.setLocalDescription(answer);
    await files.sendSignal({ kind: "sdp", id: t.id, from: me, to: t.teammate, sdpType: "answer", sdp: answer.sdp });
  } catch {
    failed(t);
  }
}
