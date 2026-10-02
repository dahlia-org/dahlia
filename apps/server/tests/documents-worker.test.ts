import { afterEach, expect, it, vi } from "vitest";
import { createRequire } from "node:module";
const { build } = createRequire(import.meta.resolve("wrangler"))("esbuild") as { build(this: void, options: { entryPoints: string[]; bundle: boolean; write: boolean; format: string; platform: string; banner: { js: string } }): Promise<{ outputFiles: { text: string }[] }> };
import { Worker as NodeWorker } from "node:worker_threads";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RemoteDocumentSession } from "../src/documents/remote-session";
import { DocumentCore } from "../src/documents/core";
import { firstText } from "./fixtures/document-helpers";
import type { PendingDocumentUpdate } from "../src/documents/session";

afterEach(() => vi.unstubAllGlobals());
it("runs the real Worker durability queue and restarts from retained edits after a Worker failure", async () => {
  const directory = await mkdtemp(join(tmpdir(), "dahlia-document-worker-"));
  const bundle = await build({ entryPoints: ["src/documents/session-worker.ts"], bundle: true, write: false, format: "esm", platform: "node",
    banner: { js: 'import{parentPort}from"node:worker_threads";globalThis.postMessage=(value)=>parentPort.postMessage(value);globalThis.onmessage=null;parentPort.on("message",data=>globalThis.onmessage?.({data}));' } });
  const path = join(directory, "worker.mjs"); await writeFile(path, bundle.outputFiles[0]!.text);
  const workers: BrowserWorker[] = [];
  class BrowserWorker {
    onmessage?: (event: { data: unknown }) => void;
    onerror?: () => void;
    private readonly worker = new NodeWorker(path);
    constructor() { workers.push(this); this.worker.on("message", (data: unknown) => this.onmessage?.({ data })); this.worker.on("error", () => this.onerror?.()); }
    postMessage(value: unknown) { this.worker.postMessage(value); }
    terminate() { void this.worker.terminate(); }
    crash() { this.onerror?.(); }
  }
  vi.stubGlobal("Worker", BrowserWorker);
  const editor = new DocumentCore(), server = new DocumentCore(); editor.insertText("before", () => crypto.randomUUID());
  const retained = new DocumentCore(editor.checkpoint());
  const pending: PendingDocumentUpdate[] = [], notifications: unknown[] = []; let sequence = 0, fail = true;
  const session = new RemoteDocumentSession({ newID: () => crypto.randomUUID(), snapshot: () => retained.checkpoint(false),
    append: async (update, local) => { if (fail && local) throw new Error("save failure"); retained.apply(update); const next = ++sequence; if (local) pending.push({ sequence: next, update }); return next; },
    pending: async () => [...pending], acknowledge: async (through) => { while (pending[0] && pending[0].sequence <= through) pending.shift(); },
    checkpoint: async (state) => { notifications.push(state); },
    exchange: async (request) => { if (request.update) server.apply(request.update); return { accepted: true, generation: null, revision: 1, vector: server.vector(), update: server.difference(request.vector) }; },
  }, { checkpoint: editor.checkpoint(), generation: null, revision: 0 });
  try {
    const vector = editor.vector(); firstText(editor).insert(0, "saved "); const update = editor.difference(vector);
    await expect(session.accept(update, true)).rejects.toThrow("save failure"); expect(pending).toHaveLength(0);
    workers[0]!.crash();
    fail = false; await session.accept(update, true); expect(pending).toHaveLength(1);
    expect(notifications[0]).toMatchObject({ update }); expect(notifications[0]).not.toHaveProperty("checkpoint");
    workers[1]!.crash(); await session.flush();
    expect(workers).toHaveLength(3); expect(pending).toHaveLength(0); expect(server.projection().text).toBe("saved before");
  } finally { await session.close(); editor.destroy(); server.destroy(); retained.destroy(); for (const worker of workers) worker.terminate(); await rm(directory, { recursive: true }); }
});
