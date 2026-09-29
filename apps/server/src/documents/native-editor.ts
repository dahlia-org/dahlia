import * as Y from "yjs";
import { decodeBinary, encodeBinary } from "./core";
import { DocumentEditorHydration, mountDocumentEditor } from "./editor";

declare global {
  interface Window {
    webkit: { messageHandlers: { document: { postMessage(value: unknown): void } } };
    dahliaDocument: { open(checkpoint: string, editable: boolean): void; receive(update: string): void; setEditable(editable: boolean): void; command(name: string): void; drain(): string | null };
  }
}
const document = new Y.Doc();
let hydration: DocumentEditorHydration;
let initialized = false;
let pending: Uint8Array[] = [];
let sendTimer: ReturnType<typeof setTimeout> | undefined;
function sendPending() {
  sendTimer = undefined;
  if (!pending.length) return;
  const update = hydration.captureLocalUpdate(Y.mergeUpdates(pending));
  pending = [];
  window.webkit.messageHandlers.document.postMessage({ type: "update", update: encodeBinary(update) });
}
let editor: ReturnType<typeof mountDocumentEditor> | undefined;
window.dahliaDocument = {
  open(checkpoint, editable) {
    if (editor) return;
    if (checkpoint) Y.applyUpdate(document, decodeBinary(checkpoint), "remote");
    hydration = new DocumentEditorHydration(document);
    editor = mountDocumentEditor(window.document.getElementById("editor")!, document, editable);
    editor.on("create", () => { initialized = true; });
    editor.on("focus", () => window.webkit.messageHandlers.document.postMessage({ type: "focus", focused: "true" }));
    editor.on("blur", () => window.webkit.messageHandlers.document.postMessage({ type: "focus", focused: "false" }));
    document.on("update", (update: Uint8Array, origin: unknown) => {
      if (origin !== "remote" && initialized && editor?.isEditable) {
        hydration.edited();
        pending.push(update);
        // Throttle continuous typing without delaying it until the user stops.
        sendTimer ??= setTimeout(sendPending, 50);
      }
    });
  },
  drain() {
    if (!pending.length) return null;
    const update = hydration.captureLocalUpdate(Y.mergeUpdates(pending));
    clearTimeout(sendTimer); sendTimer = undefined; pending = [];
    return encodeBinary(update);
  },
  receive(update) {
    hydration.receive(decodeBinary(update));
  },
  setEditable(editable) { editor?.setEditable(editable); },
  command(name) {
    if (!editor?.isEditable) return;
    const chain = editor.chain().focus();
    if (name === "bold") chain.toggleBold().run();
    else if (name === "heading") chain.toggleHeading({ level: 2 }).run();
    else if (name === "list") chain.toggleBulletList().run();
    else if (name === "undo") chain.undo().run();
    else if (name === "redo") chain.redo().run();
  },
};
window.document.addEventListener("click", (event) => {
  const link = (event.target as HTMLElement).closest("a");
  if (link) {
    event.preventDefault();
    if (/^(https?:|mailto:)/i.test(link.href)) window.webkit.messageHandlers.document.postMessage({ type: "link", url: link.href });
  }
});
window.webkit.messageHandlers.document.postMessage({ type: "ready" });
