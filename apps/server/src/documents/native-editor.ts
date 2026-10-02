import * as Y from "yjs";
import { decodeBinary, encodeBinary, type DocumentBlock } from "./core";
import { DocumentEditorHydration, mountDocumentEditor } from "./editor";

declare global {
  interface Window {
    webkit: { messageHandlers: { document: { postMessage(value: unknown): void } } };
    dahliaDocument: { open(checkpoint: string, editable: boolean, placeholder: string): void; receive(update: string, vector?: string): void; setEditable(editable: boolean): void; drain(): { update: string; recovery?: string } | null };
  }
}
const document = new Y.Doc();
let hydration: DocumentEditorHydration;
let initialized = false;
let pending: Uint8Array[] = [];
let pendingRecovery: DocumentBlock[] = [];
let sendTimer: ReturnType<typeof setTimeout> | undefined;
function preserveRecovery(blocks: DocumentBlock[]) {
  pendingRecovery.push(...blocks); sendTimer ??= setTimeout(sendPending, 50);
}
function sendPending() {
  const batch = window.dahliaDocument.drain();
  if (batch) window.webkit.messageHandlers.document.postMessage({ type: "update", ...batch });
}
let editor: ReturnType<typeof mountDocumentEditor> | undefined;
window.dahliaDocument = {
  open(checkpoint, editable, placeholder) {
    if (editor) return;
    if (checkpoint) Y.applyUpdate(document, decodeBinary(checkpoint, Infinity), "remote");
    hydration = new DocumentEditorHydration(document, preserveRecovery);
    editor = mountDocumentEditor(window.document.getElementById("editor")!, document, editable, placeholder,
      (message) => window.webkit.messageHandlers.document.postMessage({ type: "error", message }), preserveRecovery);
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
    if (!pending.length && !pendingRecovery.length) return null;
    const update = hydration.captureLocalUpdate(Y.mergeUpdates(pending));
    const recovery = pendingRecovery.length ? JSON.stringify(pendingRecovery) : undefined;
    clearTimeout(sendTimer); sendTimer = undefined; pending = [];
    pendingRecovery = [];
    return { update: encodeBinary(update), ...(recovery ? { recovery } : {}) };
  },
  receive(update, vector) {
    hydration.receive(decodeBinary(update, Infinity), vector ? decodeBinary(vector, Infinity) : undefined);
  },
  setEditable(editable) { editor?.setEditable(editable); },
};
window.document.addEventListener("click", (event) => {
  const link = (event.target as HTMLElement).closest("a");
  if (link) {
    event.preventDefault();
    if (/^(https?:|mailto:)/i.test(link.href)) window.webkit.messageHandlers.document.postMessage({ type: "link", url: link.href });
  }
});
window.webkit.messageHandlers.document.postMessage({ type: "ready" });
