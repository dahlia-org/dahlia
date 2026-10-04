// Open scripts/document-browser-benchmark.html with the local Vite server; synthetic content only.
import * as Y from "yjs";
import { DocumentCore, decodeBinary, encodeBinary } from "@dahlia-ai/ui/documents/core";
import { DocumentEditorHydration, mountDocumentEditor } from "@dahlia-ai/ui/documents/editor";
import { RemoteDocumentSession } from "@dahlia-ai/ui/documents/remote-session";
import type { PendingDocumentUpdate } from "@dahlia-ai/ui/documents/session";

export async function benchmarkDocumentBrowser(element: HTMLElement) {
  const source = new DocumentCore();
  source.insertText(Array<string>(5000).fill("日".repeat(100)).join("\n"), () => crypto.randomUUID());
  const checkpoint = source.checkpoint(); source.destroy();
  const document = new Y.Doc(), retained = new Y.Doc(); Y.applyUpdate(document, decodeBinary(checkpoint)); Y.applyUpdate(retained, decodeBinary(checkpoint));
  const hydration = new DocumentEditorHydration(document);
  const pending: PendingDocumentUpdate[] = []; let sequence = 0;
  let saves: Promise<void>[] = [];
  const session = new RemoteDocumentSession({ newID: () => crypto.randomUUID(), snapshot: () => encodeBinary(Y.encodeStateAsUpdate(retained)),
    append: (update, local) => { Y.applyUpdate(retained, decodeBinary(update)); const next = ++sequence; if (local) pending.push({ sequence: next, update }); return Promise.resolve(next); },
    pending: () => Promise.resolve(pending), acknowledge: async () => {}, exchange: () => Promise.reject(new Error("network excluded")),
    checkpoint: ({ update, vector }) => { hydration.receive(decodeBinary(update), decodeBinary(vector)); return Promise.resolve(); },
  }, { checkpoint, generation: null, revision: 0 });
  const start = performance.now();
  const editor = mountDocumentEditor(element, document, true, "Synthetic Notes");
  await new Promise<void>((resolve) => editor.on("create", () => resolve()));
  await session.accept("AAA=", false);
  const initializationMs = performance.now() - start;
  document.on("update", (update: Uint8Array, origin: unknown) => {
    if (origin === "remote") return;
    hydration.edited(); saves.push(session.accept(encodeBinary(hydration.captureLocalUpdate(update)), true));
  });
  editor.commands.setTextSelection(2);
  editor.commands.insertContent("x"); await Promise.all(saves); saves = [];
  const tasks: number[] = [], timings: number[] = [], acknowledgements: number[] = [];
  const observer = new PerformanceObserver((entries) => { for (const entry of entries.getEntries()) tasks.push(entry.duration); });
  observer.observe({ type: "longtask" });
  try {
    for (let i = 0; i < 40; i++) {
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      const began = performance.now(); editor.commands.insertContent("x");
      timings.push(performance.now() - began);
      await Promise.all(saves); saves = []; acknowledgements.push(performance.now() - began);
    }
    await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    tasks.push(...observer.takeRecords().map((entry) => entry.duration));
    const percentile = (values: number[]) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * 0.95) - 1]!;
    return { runtime: navigator.userAgent, blocks: 5000, utf16: 504999, samples: timings.length,
      initializationMs, inputDispatchP95Ms: percentile(timings), saveAcknowledgementP95Ms: percentile(acknowledgements),
      mainThreadLongTasksMs: tasks, unsent: pending.length };
  } finally { observer.disconnect(); await session.close(); editor.destroy(); document.destroy(); retained.destroy(); }
}
