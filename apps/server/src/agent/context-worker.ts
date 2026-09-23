import { setTimeout as delay } from "node:timers/promises";
import type { ChatMemoryService } from "./context-service";

export class ChatMemoryWorker {
  private readonly abort = new AbortController();
  private running?: Promise<void>;
  constructor(private readonly service: ChatMemoryService) {}
  start() { this.running ??= this.run(); }
  async stop() { this.abort.abort(); await this.running; }
  private async run() {
    while (!this.abort.signal.aborted) {
      try { await this.service.tick(this.abort.signal); }
      catch { if (!this.abort.signal.aborted) console.warn(JSON.stringify({ event: "chat_memory_worker_failed" })); }
      await delay(1000, undefined, { signal: this.abort.signal, ref: false }).catch(() => undefined);
    }
  }
}
