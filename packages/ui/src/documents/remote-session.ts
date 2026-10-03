import { DocumentSession, type DocumentHost } from "./session";

/** Small request/response bridge; the existing session remains the non-browser test adapter. */
export class RemoteDocumentSession {
  generation: string | null;
  revision: number;
  private sequence = 0;
  private readonly calls = new Map<number, { resolve(): void; reject(error: Error): void }>();
  private worker!: Worker;
  private ready: Promise<void>;
  private failed = false;
  private restarting?: Promise<void>;
  constructor(private readonly host: DocumentHost, initial: ConstructorParameters<typeof DocumentSession>[1]) {
    this.generation = initial?.generation ?? null; this.revision = initial?.revision ?? 0;
    this.ready = this.initialize(initial);
    void this.ready.catch(() => {});
  }
  private initialize(initial: ConstructorParameters<typeof DocumentSession>[1], pending: Awaited<ReturnType<DocumentHost["pending"]>> = []) {
    const worker = new Worker(new URL("./session-worker.ts", import.meta.url), { type: "module" });
    this.worker = worker; this.failed = false;
    worker.onmessage = (event: MessageEvent<{ id: number; host?: keyof DocumentHost; args?: unknown[]; error?: string }>) => {
      const message = event.data;
      if (message.host) {
        const method = message.host;
        if (method === "checkpoint") {
          const state = message.args![0] as Parameters<DocumentHost["checkpoint"]>[0];
          this.generation = state.generation; this.revision = state.revision;
        }
        void Promise.resolve().then(() => (this.host[method] as (...args: unknown[]) => unknown)(...message.args!))
          .then((result) => worker.postMessage({ id: message.id, result }),
            (error: unknown) => worker.postMessage({ id: message.id, error: error instanceof Error ? error.message : String(error) }));
      } else {
        const call = this.calls.get(message.id); this.calls.delete(message.id);
        if (message.error) call?.reject(new Error(message.error)); else call?.resolve();
      }
    };
    worker.onerror = () => {
      this.failed = true; worker.terminate();
      for (const call of this.calls.values()) call.reject(new Error("document_worker_failed"));
      this.calls.clear();
    };
    return this.call("initialize", [initial, pending]);
  }
  private async ensureReady() {
    if (this.failed) {
      if (!this.host.snapshot) throw new Error("document_worker_failed");
      this.restarting ??= this.host.pending().then((pending) => {
        this.ready = this.initialize({ checkpoint: this.host.snapshot!(), generation: this.generation, revision: this.revision }, pending);
        return this.ready;
      }).finally(() => { this.restarting = undefined; });
      await this.restarting;
    }
    await this.ready;
  }
  private call(method: string, args: unknown[] = []): Promise<void> {
    return new Promise((resolve, reject) => {
      const id = ++this.sequence; this.calls.set(id, { resolve, reject }); this.worker.postMessage({ id, method, args });
    });
  }
  async accept(...args: Parameters<DocumentSession["accept"]>) { await this.ensureReady(); await this.call("accept", args); }
  async synchronize() { await this.ensureReady(); await this.call("synchronize"); }
  async flush() { await this.ensureReady(); await this.call("flush"); }
  async close() { if (this.failed) { this.worker.terminate(); return; } try { await this.ready; await this.call("close"); } finally { this.worker.terminate(); } }
  // Only the headless adapter exposes Yjs state. UI reads its editor replica on explicit copy/restore.
  get core(): DocumentSession["core"] { throw new Error("document_core_owned_by_worker"); }
}
