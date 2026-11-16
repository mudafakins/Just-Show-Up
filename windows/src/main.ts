// Just Show Up! for Windows: the panel, the team, the rooms and the calls.
// It speaks the same protocol as the Mac app (TeamStore.swift / CallEngine.swift):
// the same Supabase tables and functions, the same presence and call messages,
// the same LiveKit rooms and the same drawing messages, so Mac and Windows teammates
// share one team.
import { createClient, type RealtimeChannel, type SupabaseClient } from "@supabase/supabase-js";
import { invoke } from "@tauri-apps/api/core";
import { emitTo, listen } from "@tauri-apps/api/event";
import {
  LocalTrackPublication,
  RemoteParticipant,
  RemoteTrack,
  Room,
  RoomEvent,
  Track,
  type Participant,
} from "livekit-client";
import { InkBoard, InkView, keepInk, norm, type InkMessage } from "./ink";
import { startRingtone, stopRingtone } from "./ringtone";
import { playSound, sounds } from "./sounds";
import { checkForUpdate, installUpdate, update, updateBusy } from "./updater";

// ---------------------------------------------------------------- model

const ROOMS = [1, 2, 3];
const roomName = (n: number) => `Room ${n}`;
const PALETTE = ["#ff2d55", "#ff9500", "#34c759", "#30b0c7", "#007aff", "#af52de", "#ffcc00", "#ff3b30"];

interface Teammate {
  id: string;
  name: string;
  colorIndex: number;
}

interface ProfileRow {
  id: string;
  name: string;
  color_index: number;
  team_id: string | null;
}

interface CallState {
  room: string;
  number: number;
  connecting: boolean;
  connected: Set<string>;
}

/** Same JSON as the Mac app's CallSignal. */
interface CallSignal {
  kind: "ring" | "cancel" | "decline" | "busy";
  from: string;
  to: string;
  room: string;
  name: string;
  roomNumber?: number | null;
}

type Phase = "config" | "loading" | "welcome" | "team";

const S = {
  phase: "loading" as Phase,
  me: undefined as Teammate | undefined,
  teammates: [] as Teammate[],
  teamID: undefined as string | undefined,
  teamCode: undefined as string | undefined,
  error: undefined as string | undefined,
  notice: undefined as string | undefined,
  editingName: false,
  doNotDisturb: localStorage.getItem("dnd") === "1",
  muted: false,
  call: undefined as CallState | undefined,
  online: new Set<string>(),
  roomMembers: new Map<string, number>(),
  ringing: new Map<string, number>(),
  incoming: undefined as { from: string; fromName: string; roomNumber: number } | undefined,
  sharing: false,
  drawing: false,
  sharingUsers: new Map<string, RemoteTrack>(),
  viewing: undefined as string | undefined,
  speaking: new Set<string>(),
  search: "",
};

const env = import.meta.env;
const sb: SupabaseClient | undefined =
  env.VITE_SUPABASE_URL && env.VITE_SUPABASE_KEY
    ? createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_KEY, {
        auth: { persistSession: true, autoRefreshToken: true },
      })
    : undefined;

let channel: RealtimeChannel | undefined;
let room: Room | undefined;
let shareInfoTimer: number | undefined;
let shareAspect = 0;
let overlayOpen = false;
const boards = new Map<string, InkBoard>();

const colorOf = (id: string) => {
  const person = norm(id) === S.me?.id ? S.me : S.teammates.find((t) => t.id === norm(id));
  return PALETTE[(person?.colorIndex ?? 0) % PALETTE.length];
};
const nameOf = (id: string) => {
  if (norm(id) === S.me?.id) return S.me?.name ?? "Me";
  return S.teammates.find((t) => t.id === norm(id))?.name ?? "Teammate";
};
const firstName = (name: string) => name.split(" ")[0] || name;
const isOnline = (t: Teammate) => S.online.has(t.id);
const teamRoomID = (n: number) => `${S.teamID}:room${n}`;

function roomOf(t: Teammate): number | undefined {
  if (S.call && !S.call.connecting && S.call.connected.has(t.id)) return S.call.number;
  return S.roomMembers.get(t.id);
}
const isInMyRoom = (t: Teammate) => !!S.call && roomOf(t) === S.call.number;
const teammatesIn = (n: number) => S.teammates.filter((t) => roomOf(t) === n);

function errorText(error: unknown): string {
  if (error && typeof error === "object" && "message" in error) return String((error as Error).message);
  return String(error);
}

// ---------------------------------------------------------------- team

async function start() {
  if (!sb) {
    S.phase = "config";
    render();
    return;
  }
  const { data } = await sb.auth.getSession();
  if (data.session) await enterTeamIfMember();
  else S.phase = "welcome";
  render();
  if (S.phase === "welcome") void invoke("show_panel");
}

async function enterTeamIfMember() {
  await reloadTeam();
  if (S.phase === "team") await joinPresence();
}

/** Loads my profile, teammates and the team code (row-level security limits rows to my team). */
async function reloadTeam() {
  if (!sb) return;
  const { data: auth } = await sb.auth.getSession();
  const userID = auth.session?.user.id;
  if (!userID) {
    S.phase = "welcome";
    return render();
  }
  const profiles = await sb.from("profiles").select("*");
  if (profiles.error) {
    S.error = profiles.error.message;
    if (S.phase === "loading") S.phase = "welcome";
    return render();
  }
  const rows = profiles.data as ProfileRow[];
  const mine = rows.find((p) => p.id === userID);
  if (!mine?.team_id) {
    if (S.phase === "team") await resetToWelcome();
    else S.phase = "welcome";
    return render();
  }
  const teams = await sb.from("teams").select("code");
  S.teamID = mine.team_id;
  S.teamCode = (teams.data?.[0] as { code?: string } | undefined)?.code;
  S.me = { id: mine.id, name: mine.name || "Me", colorIndex: mine.color_index };
  S.teammates = rows
    .filter((p) => p.id !== userID)
    .map((p) => ({ id: p.id, name: p.name || "Teammate", colorIndex: p.color_index }));
  S.phase = "team";
  sendPeopleToOverlay();
  render();
}

async function onboard(action: (client: SupabaseClient) => PromiseLike<{ error: unknown }>) {
  if (!sb) return;
  S.error = undefined;
  render();
  const { data } = await sb.auth.getSession();
  if (!data.session) {
    // Each computer gets a silent anonymous account; there is nothing to sign in to.
    const signIn = await sb.auth.signInAnonymously();
    if (signIn.error) {
      S.error = signIn.error.message;
      return render();
    }
  }
  const result = await action(sb);
  if (result.error) {
    S.error = errorText(result.error);
    return render();
  }
  await enterTeamIfMember();
}

/** Runs a team action, then reloads the team. Returns false if the server refused. */
async function run(action: (client: SupabaseClient) => PromiseLike<{ error: unknown }>) {
  if (!sb) return false;
  S.error = undefined;
  const result = await action(sb);
  if (result.error) {
    S.error = errorText(result.error);
    render();
    return false;
  }
  await reloadTeam();
  return true;
}

async function resetToWelcome() {
  leaveRoom();
  stopIncomingRing();
  await leavePresence();
  S.me = undefined;
  S.teammates = [];
  S.teamID = undefined;
  S.teamCode = undefined;
  S.phase = "welcome";
}

// ---------------------------------------------------------------- presence and signals

async function joinPresence() {
  if (!sb || !S.teamID || !S.me || channel) return;
  const me = S.me.id;
  const ch = sb.channel(`team:${S.teamID.toLowerCase()}`, { config: { presence: { key: me } } });
  channel = ch;

  ch.on("presence", { event: "sync" }, () => {
    const state = ch.presenceState<{ user_id: string; room?: number | null }>();
    const online = new Set<string>();
    const rooms = new Map<string, number>();
    for (const entries of Object.values(state)) {
      for (const entry of entries) {
        const id = norm(entry.user_id);
        online.add(id);
        if (entry.room && ROOMS.includes(entry.room)) rooms.set(id, entry.room);
      }
    }
    rooms.delete(me);
    const unknown = [...online].some((id) => id !== me && !S.teammates.some((t) => t.id === id));
    S.online = online;
    S.roomMembers = rooms;
    // Someone I'm calling arrived in the room I called them to.
    for (const [id, n] of S.ringing) if (rooms.get(id) === n) S.ringing.delete(id);
    if (S.incoming && !online.has(S.incoming.from)) stopIncomingRing();
    if (unknown) void reloadTeam(); // a new teammate just joined
    render();
  });

  ch.on("broadcast", { event: "call" }, ({ payload }) => void receive(payload as CallSignal));

  ch.subscribe((status) => {
    if (status === "SUBSCRIBED") void updatePresence();
    if (status === "CHANNEL_ERROR") {
      S.error = "Couldn't connect for live presence.";
      render();
    }
  });
}

async function leavePresence() {
  if (channel && sb) {
    await channel.untrack();
    await sb.removeChannel(channel);
  }
  channel = undefined;
  S.online = new Set();
  S.roomMembers = new Map();
}

/** Tells the team which room I'm in, so they see it without being in it. */
async function updatePresence() {
  if (!channel || !S.me) return;
  const roomNumber = S.call && !S.call.connecting ? S.call.number : null;
  await channel.track({ user_id: S.me.id, room: roomNumber });
}

async function send(kind: CallSignal["kind"], to: string, roomNumber: number | null) {
  if (!channel || !S.me) return;
  const signal: CallSignal = { kind, from: S.me.id, to, room: "", name: S.me.name, roomNumber };
  await channel.send({ type: "broadcast", event: "call", payload: signal });
}

async function receive(signal: CallSignal) {
  if (!S.me || norm(signal.to) !== S.me.id) return;
  const from = norm(signal.from);
  const name = S.teammates.find((t) => t.id === from)?.name ?? signal.name;

  switch (signal.kind) {
    case "ring": {
      const n = signal.roomNumber;
      if (!n || !ROOMS.includes(n)) return;
      if (S.call?.number === n) return; // already in the room they're calling me to
      if (S.doNotDisturb) return void send("busy", from, n);
      S.incoming = { from, fromName: name, roomNumber: n };
      startRingtone();
      void invoke("show_panel");
      render();
      // Stop by itself if the caller's cancel never arrives.
      setTimeout(() => {
        if (S.incoming?.from !== from) return;
        stopIncomingRing();
        S.notice = `Missed call from ${name}.`;
        render();
      }, 40_000);
      break;
    }
    case "cancel":
      if (S.incoming?.from !== from) return;
      stopIncomingRing();
      S.notice = `Missed call from ${name}.`;
      render();
      break;
    case "decline":
    case "busy":
      if (!S.ringing.has(from)) return;
      S.ringing.delete(from);
      S.notice = signal.kind === "busy" ? `${name} is on Do Not Disturb.` : `${name} declined.`;
      render();
      break;
  }
}

// ---------------------------------------------------------------- calling

function ring(t: Teammate, n: number) {
  if (!isOnline(t) || roomOf(t) === n) return;
  if (S.call?.number !== n) joinRoom(n);
  S.ringing.set(t.id, n);
  S.notice = undefined;
  render();
  void send("ring", t.id, n);
  setTimeout(() => {
    if (S.ringing.get(t.id) !== n) return;
    S.ringing.delete(t.id);
    void send("cancel", t.id, n);
    S.notice = `${t.name} didn't answer.`;
    render();
  }, 30_000);
}

function stopCalling(t: Teammate) {
  const n = S.ringing.get(t.id);
  if (n === undefined) return;
  S.ringing.delete(t.id);
  void send("cancel", t.id, n);
  render();
}

function cancelAllCalls() {
  for (const [id, n] of S.ringing) void send("cancel", id, n);
  S.ringing.clear();
}

function acceptRing() {
  const ring = S.incoming;
  if (!ring) return;
  stopIncomingRing();
  joinRoom(ring.roomNumber);
}

function declineRing() {
  const ring = S.incoming;
  if (!ring) return;
  stopIncomingRing();
  void send("decline", ring.from, ring.roomNumber);
  render();
}

function stopIncomingRing() {
  S.incoming = undefined;
  stopRingtone();
}

// ---------------------------------------------------------------- rooms (LiveKit)

function joinRoom(n: number) {
  if (!S.teamID || !ROOMS.includes(n) || S.call?.number === n) return;
  const switching = !!S.call;
  if (S.incoming) stopIncomingRing();
  S.notice = undefined;
  S.error = undefined;
  cancelAllCalls();
  void stopSharing();
  const name = teamRoomID(n);
  S.call = { room: name, number: n, connecting: true, connected: new Set() };
  render();
  void (async () => {
    if (switching) await disconnectRoom();
    if (await connectRoom(name)) await updatePresence();
  })();
}

async function connectRoom(name: string): Promise<boolean> {
  if (!sb) return false;
  const { data, error } = await sb.functions.invoke("livekit-token", { body: { room: name } });
  if (error) {
    let message = error.message;
    try {
      const body = await (error as { context?: Response }).context?.json();
      if (body?.error) message = body.error;
    } catch {
      /* keep the generic message */
    }
    if (S.call?.room === name) S.call = undefined;
    S.error = `Couldn't join the room: ${message}`;
    render();
    return false;
  }
  if (S.call?.room !== name) return false;

  const lk = new Room({
    adaptiveStream: false,
    dynacast: false,
    // Echo cancellation, noise suppression and automatic gain, like the Mac app.
    audioCaptureDefaults: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    publishDefaults: {
      audioPreset: { maxBitrate: 48_000 },
      dtx: true,
      red: true,
      screenShareEncoding: { maxBitrate: 6_000_000, maxFramerate: 15 },
      videoCodec: "h264",
      degradationPreference: "maintain-resolution",
    },
  });
  wireRoom(lk);
  room = lk;
  try {
    await lk.connect(data.url, data.token);
  } catch (e) {
    await disconnectRoom();
    if (S.call?.room === name) S.call = undefined;
    S.error = `Couldn't join the room: ${errorText(e)}`;
    render();
    return false;
  }
  if (S.call?.room !== name) {
    await disconnectRoom();
    return false;
  }
  S.call.connecting = false;
  joinedAt = performance.now();
  playSound("join");
  // A missing or blocked microphone shouldn't keep you out of the room:
  // stay in it muted (you can still listen, share and draw) and say why.
  await lk.startAudio().catch(() => {});
  if (!S.muted) {
    try {
      await lk.localParticipant.setMicrophoneEnabled(true);
    } catch (e) {
      S.muted = true;
      S.notice = micProblem(e);
    }
  }
  reportParticipants();
  return true;
}

function micProblem(e: unknown): string {
  const name = e && typeof e === "object" && "name" in e ? String((e as Error).name) : "";
  if (name === "NotFoundError" || name === "OverconstrainedError")
    return "No microphone found, so you're muted. Plug one in, then click the mic button.";
  if (name === "NotAllowedError" || name === "SecurityError")
    return "Windows blocked the microphone, so you're muted. Turn on Settings > Privacy & security > Microphone > \"Let desktop apps access your microphone\", then click the mic button.";
  if (name === "NotReadableError" || name === "AbortError")
    return "Another app is using the microphone, so you're muted. Close it, then click the mic button.";
  return `Microphone problem (${errorText(e)}), so you're muted.`;
}

function participantID(p?: Participant) {
  return p ? norm(p.identity) : undefined;
}

let joinedAt = 0;

function reportParticipants() {
  if (!room || !S.call) return;
  const before = S.call.connected;
  const now = new Set([...room.remoteParticipants.values()].map((p) => norm(p.identity)));
  // Chime when someone joins or leaves my room (not for the people already there).
  if (!S.call.connecting && performance.now() - joinedAt > 1500) {
    if ([...now].some((id) => !before.has(id))) playSound("teammateJoined");
    else if ([...before].some((id) => !now.has(id))) playSound("teammateLeft");
  }
  S.call.connected = now;
  for (const id of S.call.connected) S.ringing.delete(id);
  render();
}

function wireRoom(lk: Room) {
  lk.on(RoomEvent.ParticipantConnected, reportParticipants);
  lk.on(RoomEvent.ParticipantDisconnected, (p: RemoteParticipant) => {
    const id = norm(p.identity);
    for (const board of boards.values()) board.removeUser(id);
    remoteShareStopped(id);
    reportParticipants();
  });
  lk.on(RoomEvent.TrackSubscribed, (track: RemoteTrack, _pub, p: RemoteParticipant) => {
    if (track.kind === Track.Kind.Audio) {
      const element = track.attach();
      document.getElementById("audio")!.appendChild(element);
    } else if (track.source === Track.Source.ScreenShare) {
      remoteShareStarted(norm(p.identity), track);
    }
  });
  lk.on(RoomEvent.TrackUnsubscribed, (track: RemoteTrack, _pub, p: RemoteParticipant) => {
    track.detach().forEach((el) => el.remove());
    if (track.source === Track.Source.ScreenShare) remoteShareStopped(norm(p.identity));
  });
  lk.on(RoomEvent.ActiveSpeakersChanged, (speakers: Participant[]) => {
    S.speaking = new Set(speakers.map((s) => norm(s.identity)).filter((id) => id !== S.me?.id));
    render();
  });
  lk.on(RoomEvent.DataReceived, (payload, p, _kind, topic) => {
    const from = participantID(p);
    if (topic !== "ink" || !from) return;
    try {
      const message = JSON.parse(new TextDecoder().decode(payload)) as InkMessage;
      boardFor(message.b).apply(message, from);
      if (overlayOpen && norm(message.b) === S.me?.id) {
        void emitTo("overlay", "ink-message", { message, from });
      }
    } catch {
      /* not a drawing message */
    }
  });
  lk.on(RoomEvent.LocalTrackUnpublished, (pub: LocalTrackPublication) => {
    // Sharing stopped from Windows' own "Stop sharing" bar.
    if (pub.source === Track.Source.ScreenShare && S.sharing) void stopSharing();
  });
  lk.on(RoomEvent.Disconnected, () => {
    if (room !== lk) return; // our own disconnect
    room = undefined;
    cleanUpSharing();
    if (S.call) {
      S.call = undefined;
      playSound("leave");
      S.notice = "You were disconnected from the room.";
      void updatePresence();
      render();
    }
  });
}

async function disconnectRoom() {
  const old = room;
  room = undefined;
  cleanUpSharing();
  await old?.disconnect();
  document.getElementById("audio")!.replaceChildren();
}

function leaveRoom() {
  if (!S.call) return;
  S.call = undefined;
  playSound("leave");
  cancelAllCalls();
  S.muted = false;
  render();
  void (async () => {
    await disconnectRoom();
    await updatePresence();
  })();
}

async function toggleMute() {
  S.muted = !S.muted;
  S.notice = undefined;
  render();
  try {
    await room?.localParticipant.setMicrophoneEnabled(!S.muted);
  } catch (e) {
    S.muted = true;
    S.notice = micProblem(e);
    render();
  }
}

// ---------------------------------------------------------------- drawing

function boardFor(id: string) {
  const key = norm(id);
  let board = boards.get(key);
  if (!board) {
    board = new InkBoard();
    boards.set(key, board);
  }
  return board;
}

/** Applies my own drawing immediately, then sends it to everyone in the room. */
function sendInk(message: InkMessage, fromOverlay = false) {
  if (!room || !S.me) return;
  boardFor(message.b).apply(message, S.me.id);
  if (!fromOverlay && overlayOpen && norm(message.b) === S.me.id) {
    void emitTo("overlay", "ink-message", { message, from: S.me.id });
  }
  // Strokes must all arrive; pointer positions can be dropped if the network is busy.
  const reliable = !["cursor", "leave", "info"].includes(message.k);
  void room.localParticipant.publishData(new TextEncoder().encode(JSON.stringify(message)), {
    reliable,
    topic: "ink",
  });
}

function sendPeopleToOverlay() {
  if (!overlayOpen || !S.me) return;
  const everyone = [S.me, ...S.teammates];
  void emitTo("overlay", "ink-people", {
    me: S.me.id,
    colors: Object.fromEntries(everyone.map((t) => [t.id, colorOf(t.id)])),
    names: Object.fromEntries(everyone.map((t) => [t.id, t.name])),
  });
}

// ---------------------------------------------------------------- sharing my screen

async function startSharing() {
  if (!room || !S.me) return;
  S.error = undefined;
  try {
    await room.localParticipant.setScreenShareEnabled(
      true,
      {
        audio: false,
        resolution: { width: 2560, height: 1440, frameRate: 15 },
        contentHint: "text",
        video: { displaySurface: "monitor" },
        selfBrowserSurface: "exclude",
        surfaceSwitching: "exclude",
      },
      {
        screenShareEncoding: { maxBitrate: 6_000_000, maxFramerate: 15 },
        videoCodec: "h264",
        degradationPreference: "maintain-resolution",
      },
    );
  } catch (e) {
    // Cancelling the picker isn't an error worth showing.
    if (!/denied|cancel|abort/i.test(errorText(e))) S.error = `Couldn't share the screen: ${errorText(e)}`;
    return render();
  }
  const track = room.localParticipant.getTrackPublication(Track.Source.ScreenShare)?.track;
  if (!track) return;
  S.sharing = true;
  const settings = track.mediaStreamTrack.getSettings();
  shareAspect = settings.width && settings.height ? settings.width / settings.height : 16 / 9;
  boardFor(S.me.id).reset();

  // The see-through layer where teammates' drawings appear. It can cover a whole screen;
  // a single shared window can't be followed, so then only viewers see the drawings.
  if ((settings as { displaySurface?: string }).displaySurface !== "window") {
    // Mark it open first: the overlay may say "ready" before invoke() returns.
    overlayOpen = true;
    try {
      await invoke("open_overlay", { aspect: shareAspect });
      sendPeopleToOverlay();
    } catch (e) {
      overlayOpen = false;
      S.notice = `Drawings won't show on your screen: ${errorText(e)}`;
    }
  } else {
    S.notice = "Teammates can draw on this window, but only they see it. Share your entire screen to see drawings too.";
  }
  const sendInfo = () => S.me && sendInk({ k: "info", b: S.me.id, a: shareAspect });
  sendInfo();
  shareInfoTimer = window.setInterval(sendInfo, 1000);
  render();
}

async function stopSharing() {
  if (!S.sharing) return;
  cleanUpSharing();
  render();
  await room?.localParticipant.setScreenShareEnabled(false);
}

function cleanUpSharing() {
  S.sharing = false;
  S.drawing = false;
  if (shareInfoTimer !== undefined) window.clearInterval(shareInfoTimer);
  shareInfoTimer = undefined;
  if (overlayOpen) void invoke("close_overlay");
  overlayOpen = false;
  if (S.me) boards.get(S.me.id)?.reset();
}

function toggleDrawMode() {
  if (!S.sharing || !overlayOpen) return;
  S.drawing = !S.drawing;
  void invoke("set_overlay_interactive", { on: S.drawing });
  void emitTo("overlay", "ink-interactive", S.drawing);
  render();
}

void listen("overlay-ready", () => {
  sendPeopleToOverlay();
  void emitTo("overlay", "ink-interactive", S.drawing);
});
void listen<InkMessage>("overlay-ink", (event) => sendInk(event.payload, true));
void listen("overlay-exit", () => {
  if (S.drawing) toggleDrawMode();
});

// ---------------------------------------------------------------- watching a teammate's screen

const viewerEl = document.getElementById("viewer")!;
const panelEl = document.getElementById("panel")!;
const video = document.getElementById("viewer-video") as HTMLVideoElement;
let viewerInk: InkView | undefined;

function remoteShareStarted(user: string, track: RemoteTrack) {
  S.sharingUsers.set(user, track);
  if (!S.viewing) openViewer(user);
  render();
}

function remoteShareStopped(user: string) {
  if (!S.sharingUsers.has(user)) return;
  S.sharingUsers.delete(user);
  boards.delete(user);
  if (S.viewing === user) {
    const next = S.sharingUsers.keys().next().value;
    if (next) openViewer(next);
    else closeViewer();
  }
  render();
}

function openViewer(user: string) {
  const track = S.sharingUsers.get(user);
  if (!track || !S.me) return;
  S.viewing = user;
  track.attach(video);
  const board = boardFor(user);
  board.reset();
  const canvas = document.getElementById("viewer-ink") as HTMLCanvasElement;
  const people = { me: S.me.id, color: colorOf, name: nameOf };
  if (!viewerInk) {
    viewerInk = new InkView(canvas, board, user, people, (m) => sendInk(m), true);
  } else {
    viewerInk.people = people;
    viewerInk.attach(board, user);
  }
  viewerInk.interactive = true;
  const dims = track.mediaStreamTrack.getSettings();
  viewerInk.fallbackAspect = dims.width && dims.height ? dims.width / dims.height : undefined;
  panelEl.hidden = true;
  viewerEl.hidden = false;
  renderViewerControls();
  void invoke("enter_viewer", { title: `${nameOf(user)}’s Screen — drag to draw` });
}

function closeViewer() {
  if (S.viewing) S.sharingUsers.get(S.viewing)?.detach(video);
  viewerInk?.finish();
  S.viewing = undefined;
  viewerEl.hidden = true;
  panelEl.hidden = false;
  void invoke("enter_panel", { show: false });
  render();
}

function renderViewerControls() {
  const pin = document.getElementById("viewer-pin")!;
  pin.textContent = keepInk.get() ? "📌 Keep" : "Fade";
  pin.title = keepInk.get()
    ? "Drawings stay until cleared. Click to make them fade."
    : "Drawings fade. Click to keep them until cleared.";
}

document.getElementById("viewer-pin")!.addEventListener("click", () => {
  keepInk.set(!keepInk.get());
  renderViewerControls();
});
document.getElementById("viewer-clear")!.addEventListener("click", () => {
  if (S.viewing) sendInk({ k: "clear", b: S.viewing });
});
void listen("viewer-closed", () => closeViewer());

// ---------------------------------------------------------------- panel UI

const esc = (text: string) =>
  text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
const initials = (name: string) =>
  name.split(" ").slice(0, 2).map((w) => w[0] ?? "").join("").toUpperCase();

let built: Phase | undefined;
let lastHeight = 0;

function render() {
  if (S.phase !== built) buildSkeleton();
  if (S.phase === "team") renderTeam();
  if (S.phase === "welcome") renderWelcome();
  panelEl.querySelector(".gear")?.classList.toggle("has-update", !!update.available);
  reportHeight();
}

function reportHeight() {
  if (S.viewing) return;
  requestAnimationFrame(() => {
    const height = Math.ceil(panelEl.getBoundingClientRect().height);
    if (height && height !== lastHeight) {
      lastHeight = height;
      void invoke("set_panel_height", { height });
    }
  });
}

function buildSkeleton() {
  built = S.phase;
  closeMenu();
  if (S.phase === "config") {
    panelEl.innerHTML = `<div class="welcome"><h1>Setup needed</h1>
      <div class="hint">This build has no Supabase settings. Rebuild it with the team's settings.</div>
      <div class="buttons"><button class="btn" data-action="quit">Quit</button></div></div>`;
  } else if (S.phase === "loading") {
    panelEl.innerHTML = `<div class="welcome"><div class="hint">Loading…</div></div>`;
  } else if (S.phase === "welcome") {
    panelEl.innerHTML = `<div class="welcome">
      <h1>Just Show Up!</h1>
      <input id="w-name" placeholder="Your name" autocomplete="name" />
      <input id="w-code" placeholder="Team code, e.g. MANGO-482913" hidden />
      <div class="buttons" id="w-buttons"></div>
      <div class="hint" id="w-hint">Joining? Ask a teammate for the team code.</div>
      <div class="error" id="w-error" hidden></div>
    </div>`;
    const name = document.getElementById("w-name") as HTMLInputElement;
    name.value = localStorage.getItem("displayName") ?? "";
    name.addEventListener("input", () => {
      localStorage.setItem("displayName", name.value);
      renderWelcome();
    });
    document.getElementById("w-code")!.addEventListener("input", renderWelcome);
    document.getElementById("w-code")!.addEventListener("keydown", (e) => {
      if ((e as KeyboardEvent).key === "Enter") void joinFromWelcome();
    });
  } else {
    panelEl.innerHTML = `
      <div class="header">Just Show Up!<button class="gear" data-action="gear" title="Settings">⚙︎</button></div>
      <div class="pad" id="search-wrap"><input id="search" placeholder="Find Teammates" /></div>
      <div class="pad inline" id="name-wrap" hidden>
        <input id="name-input" placeholder="Your name" />
        <button class="btn primary" data-action="save-name">Save</button>
        <button class="link" data-action="cancel-name">Cancel</button>
      </div>
      <div id="dyn"></div>`;
    const search = document.getElementById("search") as HTMLInputElement;
    search.addEventListener("input", () => {
      S.search = search.value;
      renderTeam();
      reportHeight();
    });
    const nameInput = document.getElementById("name-input") as HTMLInputElement;
    nameInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") void saveName();
      if (e.key === "Escape") setEditingName(false);
    });
  }
}

function renderWelcome() {
  const name = (document.getElementById("w-name") as HTMLInputElement).value.trim();
  const codeEl = document.getElementById("w-code") as HTMLInputElement;
  const joining = !codeEl.hidden;
  const buttons = document.getElementById("w-buttons")!;
  buttons.innerHTML = joining
    ? `<button class="btn primary" data-action="w-join" ${name && codeEl.value.trim() ? "" : "disabled"}>Join Team</button>
       <button class="link" data-action="w-back">Back</button>`
    : `<button class="btn primary" data-action="w-show-join" ${name ? "" : "disabled"}>Join a Team</button>
       <button class="btn" data-action="w-start" ${name ? "" : "disabled"}>Start a Team</button>`;
  document.getElementById("w-hint")!.hidden = joining;
  const error = document.getElementById("w-error")!;
  error.hidden = !S.error;
  error.textContent = S.error ?? "";
}

async function joinFromWelcome() {
  const name = (document.getElementById("w-name") as HTMLInputElement).value.trim();
  const code = (document.getElementById("w-code") as HTMLInputElement).value.trim();
  if (!name || !code) return;
  await onboard((c) => c.rpc("join_team", { my_name: name, team_code: code }));
}

function setEditingName(on: boolean) {
  S.editingName = on;
  document.getElementById("name-wrap")!.hidden = !on;
  document.getElementById("search-wrap")!.hidden = on;
  if (on) {
    const input = document.getElementById("name-input") as HTMLInputElement;
    input.value = S.me?.name ?? "";
    input.focus();
    input.select();
  }
  reportHeight();
}

async function saveName() {
  const value = (document.getElementById("name-input") as HTMLInputElement).value.trim();
  if (!value) return;
  if (value === S.me?.name || (await run((c) => c.rpc("set_my_name", { new_name: value })))) {
    localStorage.setItem("displayName", value);
    setEditingName(false);
  }
}

function avatar(t: Teammate) {
  return `<div class="avatar" style="background:${colorOf(t.id)}">${esc(initials(t.name))}${
    isOnline(t) ? '<span class="dot"></span>' : ""
  }</div>`;
}

function callBar(call: CallState) {
  let status: string;
  if (call.connecting) status = "Connecting…";
  else if (S.drawing) status = "Drawing · Esc to stop";
  else if (S.sharing) status = "Sharing your screen";
  else {
    const names = teammatesIn(call.number).map((t) => firstName(t.name));
    status = names.length ? `With ${names.join(", ")}` : "Just you so far";
    if (S.muted) status += " · muted";
  }
  return `<div class="bar call">
    <div class="text"><div class="title">${roomName(call.number)}</div><div class="sub">${esc(status)}</div></div>
    <button class="round ${S.muted ? "orange" : ""}" data-action="mute" title="${S.muted ? "Unmute" : "Mute"}">${S.muted ? "🔇" : "🎙"}</button>
    <button class="round ${S.sharing ? "green" : ""}" data-action="share" title="${S.sharing ? "Stop sharing" : "Share your screen"}">🖥</button>
    ${
      S.sharing && overlayOpen
        ? `<button class="round ${S.drawing ? "blue" : ""}" data-action="draw" title="${S.drawing ? "Stop drawing (Esc)" : "Draw on your own screen"}">✏️</button>`
        : ""
    }
    ${S.sharing ? `<button class="round" data-action="clear" title="Clear all drawings">🧽</button>` : ""}
    <button class="round red" data-action="leave" title="Leave the room">✕</button>
  </div>`;
}

function roomRow(n: number) {
  const inside = teammatesIn(n);
  return `<div class="row room clickable" data-action="join" data-room="${n}" title="Join ${roomName(n)}">
    <div class="icon ${inside.length ? "busy" : ""}">🔊</div>
    <div class="text"><div class="title">${roomName(n)}</div>
      <div class="sub">${inside.length ? esc(inside.map((t) => firstName(t.name)).join(", ")) : "Empty"}</div></div>
    ${inside.length ? `<button class="join" data-action="join" data-room="${n}">Join</button>` : ""}
  </div>`;
}

function teammateRow(t: Teammate) {
  const online = isOnline(t);
  const theirRoom = roomOf(t);
  const joinable = theirRoom !== undefined && theirRoom !== S.call?.number ? theirRoom : undefined;
  const sharing = S.sharingUsers.has(t.id);
  const callingTo = S.ringing.get(t.id);

  let status = online ? "Online" : "Offline";
  if (theirRoom !== undefined) status = `In ${roomName(theirRoom)}`;
  if (isInMyRoom(t)) status = S.speaking.has(t.id) ? "Speaking…" : "In the room with you";
  if (callingTo !== undefined) status = `Calling to ${roomName(callingTo)}…`;
  if (sharing) status = "Sharing their screen · click to view";

  let buttons = "";
  if (joinable !== undefined) buttons += `<button class="join" data-action="join" data-room="${joinable}">Join</button>`;
  if (online && !isInMyRoom(t)) {
    buttons +=
      callingTo !== undefined
        ? `<button class="round red" data-action="stop-calling" data-id="${t.id}" title="Stop calling ${esc(t.name)}">✕</button>`
        : `<button class="round" data-action="bell" data-id="${t.id}" title="Call ${esc(t.name)} to a room">🔔</button>`;
  }
  const clickable = sharing || joinable !== undefined;
  return `<div class="row ${clickable ? "clickable" : ""} ${online ? "" : "offline"}" data-action="${
    sharing ? "view" : joinable !== undefined ? "join" : ""
  }" data-id="${t.id}" ${joinable !== undefined ? `data-room="${joinable}"` : ""}>
    ${avatar(t)}
    <div class="text"><div class="title">${esc(t.name)}</div><div class="sub">${esc(status)}</div></div>
    ${buttons}
  </div>`;
}

function renderTeam() {
  const dyn = document.getElementById("dyn");
  if (!dyn) return;
  const sorted = [...S.teammates].sort((a, b) =>
    isOnline(a) !== isOnline(b) ? (isOnline(a) ? -1 : 1) : a.name.localeCompare(b.name),
  );
  const query = S.search.trim().toLowerCase();
  const visible = query ? sorted.filter((t) => t.name.toLowerCase().includes(query)) : sorted;

  let html = "";
  if (S.incoming) {
    html += `<div class="bar ring">
      <div class="text"><div class="title">${esc(S.incoming.fromName)}</div>
        <div class="sub">is calling you to ${roomName(S.incoming.roomNumber)}</div></div>
      <button class="round red" data-action="decline" title="Decline">✕</button>
      <button class="round green" data-action="accept" title="Accept">📞</button>
    </div>`;
  }
  for (const n of ROOMS) html += S.call?.number === n ? callBar(S.call) : roomRow(n);
  html += `<div class="divider"></div>`;
  if (S.notice) html += `<div class="notice">${esc(S.notice)}</div>`;
  if (!query) {
    html += `<div class="row clickable" data-action="copy-code" title="Click to copy the code, then send it to a teammate">
      <div class="icon">＋</div>
      <div class="text"><div class="title" id="invite-title">Invite Teammates</div>
        <div class="sub">${S.teamCode ? `Team code ${esc(S.teamCode)}` : "…"}</div></div></div>`;
  }
  html += visible.map(teammateRow).join("");
  if (query && visible.length === 0) html += `<div class="notice">No teammate matches “${esc(S.search.trim())}”.</div>`;
  if (S.error) html += `<div class="error">${esc(S.error)}</div>`;
  dyn.innerHTML = html;
}

// ---------------------------------------------------------------- menus

let menuEl: HTMLDivElement | undefined;

function closeMenu() {
  menuEl?.remove();
  menuEl = undefined;
}

function openMenu(anchor: HTMLElement, items: string) {
  closeMenu();
  const menu = document.createElement("div");
  menu.className = "menu";
  menu.innerHTML = items;
  document.body.appendChild(menu);
  const box = anchor.getBoundingClientRect();
  const width = menu.offsetWidth;
  menu.style.left = `${Math.max(6, Math.min(box.left, window.innerWidth - width - 6))}px`;
  menu.style.top = `${box.bottom + 4}px`;
  menuEl = menu;
  // Make sure the window is tall enough to show the whole menu.
  const needed = box.bottom + 4 + menu.offsetHeight + 8;
  if (needed > window.innerHeight) void invoke("set_panel_height", { height: needed });
}

function gearMenu(anchor: HTMLElement) {
  const check = (on: boolean) => (on ? "✓ " : " ");
  openMenu(
    anchor,
    `<div class="label">You: ${esc(S.me?.name ?? "")}</div>
     <button data-action="change-name">Change Name…</button><hr />
     <button data-action="dnd">${check(S.doNotDisturb)}Do Not Disturb</button>
     <button data-action="keep-ink">${check(keepInk.get())}Keep Drawings Until Cleared</button>
     <button data-action="sounds">${check(sounds.enabled())}Sounds</button><hr />
     <button data-action="copy-code">Copy Team Code</button>
     <button data-action="new-code">New Team Code</button>
     <button data-action="leave-team">Leave Team</button><hr />
     ${
       update.available
         ? S.call
           ? `<button disabled>Update to ${esc(update.available.version)} (leave the room first)</button>`
           : `<button data-action="install-update" ${updateBusy() ? "disabled" : ""}>Update to ${esc(update.available.version)}…</button>`
         : `<button data-action="check-update" ${updateBusy() ? "disabled" : ""}>Check for Updates</button>`
     }
     <div class="label">Version ${esc(update.current)}</div><hr />
     <button data-action="quit">Quit Just Show Up!</button>`,
  );
}

function bellMenu(anchor: HTMLElement, t: Teammate) {
  openMenu(
    anchor,
    ROOMS.map(
      (n) =>
        `<button data-action="call" data-id="${t.id}" data-room="${n}" ${roomOf(t) === n ? "disabled" : ""}>Call to ${roomName(n)}</button>`,
    ).join(""),
  );
}

// ---------------------------------------------------------------- clicks

document.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-action]");
  const inMenu = !!(event.target as HTMLElement).closest(".menu");
  if (!inMenu && target?.dataset.action !== "gear" && target?.dataset.action !== "bell") closeMenu();
  if (!target || !target.dataset.action) return;
  event.stopPropagation();
  const id = target.dataset.id;
  const n = Number(target.dataset.room);
  const teammate = id ? S.teammates.find((t) => t.id === id) : undefined;
  if (inMenu) closeMenu();

  switch (target.dataset.action) {
    case "gear":
      return menuEl ? closeMenu() : gearMenu(target);
    case "bell":
      return teammate && bellMenu(target, teammate);
    case "call":
      return teammate && ring(teammate, n);
    case "stop-calling":
      return teammate && stopCalling(teammate);
    case "join":
      return joinRoom(n);
    case "view":
      return id && openViewer(id);
    case "accept":
      return acceptRing();
    case "decline":
      return declineRing();
    case "mute":
      return void toggleMute();
    case "share":
      return void (S.sharing ? stopSharing() : startSharing());
    case "draw":
      return toggleDrawMode();
    case "clear":
      return S.me && sendInk({ k: "clear", b: S.me.id });
    case "leave":
      return leaveRoom();
    case "copy-code":
      if (S.teamCode) void navigator.clipboard.writeText(S.teamCode);
      S.notice = "Team code copied.";
      return render();
    case "new-code":
      return void run((c) => c.rpc("regenerate_team_code"));
    case "leave-team":
      return S.me && void run((c) => c.rpc("remove_from_team", { member: S.me!.id }));
    case "change-name":
      return setEditingName(true);
    case "save-name":
      return void saveName();
    case "cancel-name":
      return setEditingName(false);
    case "dnd":
      S.doNotDisturb = !S.doNotDisturb;
      localStorage.setItem("dnd", S.doNotDisturb ? "1" : "0");
      return render();
    case "sounds":
      sounds.setEnabled(!sounds.enabled());
      closeMenu();
      return;
    case "keep-ink":
      keepInk.set(!keepInk.get());
      return renderViewerControls();
    case "check-update":
      closeMenu();
      return void checkForUpdate(true);
    case "install-update":
      closeMenu();
      return void installUpdate();
    case "quit":
      return void invoke("quit");
    case "w-show-join":
      (document.getElementById("w-code") as HTMLInputElement).hidden = false;
      document.getElementById("w-code")!.focus();
      S.error = undefined;
      return render();
    case "w-back":
      (document.getElementById("w-code") as HTMLInputElement).hidden = true;
      S.error = undefined;
      return render();
    case "w-join":
      return void joinFromWelcome();
    case "w-start": {
      const name = (document.getElementById("w-name") as HTMLInputElement).value.trim();
      return void onboard((c) => c.rpc("create_team", { my_name: name }));
    }
  }
});

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && menuEl) closeMenu();
});

// Refresh the list each time the panel opens (new or removed teammates).
void listen("panel-shown", () => {
  if (S.phase === "team") void reloadTeam();
  if (!S.editingName) (document.getElementById("search") as HTMLInputElement | null)?.focus();
});

void start();

// Updates: check now and every few hours; a dot on the gear when one is ready.
update.onChange = (message) => {
  if (message !== undefined) S.notice = message;
  render();
};
void checkForUpdate(false);
setInterval(() => void checkForUpdate(false), 4 * 60 * 60 * 1000);
