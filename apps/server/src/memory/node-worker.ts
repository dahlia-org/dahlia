import { setTimeout as delay } from "node:timers/promises";
import type { WorkspaceMemoryService } from "./service";

export class MemoryWorker {
  private readonly abort = new AbortController();
  private running?: Promise<void>;
  constructor(private readonly memory: WorkspaceMemoryService, private readonly personal?: WorkspaceMemoryService) {}
  start() { this.running ??= this.run(); }
  async stop() { this.abort.abort(); await this.running; }
  private async run() {
    while (!this.abort.signal.aborted) {
      try {
        for (const memory of [this.memory, this.personal].filter((item): item is WorkspaceMemoryService => !!item)) {
          let after: string | undefined;
          do {
            const ids = await memory.store.due(after);
            for (const id of ids) {
              if (this.abort.signal.aborted) return;
              await memory.step(id, this.abort.signal);
            }
            after = ids.length === 100 ? ids.at(-1) : undefined;
          } while (after && !this.abort.signal.aborted);
        }
      } catch { console.warn(JSON.stringify({ level: "warn", event: "memory_worker_failed" })); }
      await delay(1000, undefined, { signal: this.abort.signal, ref: false }).catch(() => undefined);
    }
  }
}
