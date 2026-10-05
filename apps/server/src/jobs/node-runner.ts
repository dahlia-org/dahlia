import { setTimeout as delay } from "node:timers/promises";
import { log } from "../otel/log";

export class JobRunner {
  private readonly abort = new AbortController();
  private readonly active = new Set<Promise<void>>();
  private running?: Promise<void>;
  constructor(private readonly executor: { processOne(signal: AbortSignal): Promise<boolean> }, private readonly concurrency: number) {}
  start() { this.running ??= this.run(); }
  async stop() { this.abort.abort(); await this.running; }
  private async run() {
    while (!this.abort.signal.aborted) {
      let idle = false;
      while (this.active.size < this.concurrency && !this.abort.signal.aborted && !idle) {
        const task = this.executor.processOne(this.abort.signal).then((processed) => { if (!processed) idle = true; })
          .catch(() => { idle = true; if (!this.abort.signal.aborted) log("warn", "job_dispatch_failed"); })
          .finally(() => this.active.delete(task));
        this.active.add(task);
      }
      if (this.active.size) await Promise.race(this.active);
      if (idle) await delay(1000, undefined, { signal: this.abort.signal }).catch(() => undefined);
    }
    await Promise.allSettled(this.active);
  }
}
