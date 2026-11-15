// The see-through layer over my own screen while I share it: teammates' ink and
// cursors appear here, and in draw mode I can draw too. The panel window owns the
// call and forwards drawing messages to and from this window.
import { emitTo, listen } from "@tauri-apps/api/event";
import { InkBoard, InkView, type InkMessage } from "./ink";

interface People {
  me: string;
  colors: Record<string, string>;
  names: Record<string, string>;
}

let people: People = { me: "", colors: {}, names: {} };
const board = new InkBoard();
const view = new InkView(
  document.getElementById("ink") as HTMLCanvasElement,
  board,
  "",
  {
    get me() { return people.me; },
    color: (user) => people.colors[user] ?? "#ff2d55",
    name: (user) => people.names[user] ?? "Teammate",
  },
  (message) => {
    board.apply(message, people.me);
    void emitTo("main", "overlay-ink", message);
  },
  false,
);

void listen<People>("ink-people", (event) => {
  people = event.payload;
  view.boardID = people.me;
  view.schedule();
});
void listen<{ message: InkMessage; from: string }>("ink-message", (event) => {
  board.apply(event.payload.message, event.payload.from);
});
void listen<boolean>("ink-interactive", (event) => {
  view.interactive = event.payload;
  if (!event.payload) view.finish();
});

window.addEventListener("keydown", (e) => {
  if (e.key === "Escape") void emitTo("main", "overlay-exit", null);
});

// Ask the panel for names and colours now that we're listening.
void emitTo("main", "overlay-ready", null);
