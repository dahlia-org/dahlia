import { setTimeout as delay } from "node:timers/promises";
import type { MeetingSyncService } from "../sync/service";
import type { SummaryMethod } from "./model";
import type { SummaryJobStore } from "./store";

import { processSummaryJob } from "./process";

export class SummaryWorker {
  private readonly abort = new AbortController();
  private running?: Promise<void>;
  constructor(private readonly jobs: SummaryJobStore, private readonly methods: readonly SummaryMethod[], private readonly sync: MeetingSyncService) {}
  start(): void { this.running ??= this.run(); }
  async stop(): Promise<void> {
    this.abort.abort();
    await this.running;
  }
  private async run() {
    while (!this.abort.signal.aborted) {
      try {
        if (await this.processOne()) continue;
      } catch {
        console.warn(JSON.stringify({ level: "warn", event: "summary_worker_failed" }));
      }
      await delay(1_000, undefined, { ref: false });
    }
  }
  processOne(): Promise<boolean> {
    return processSummaryJob(this.jobs, this.methods, this.sync, this.abort.signal);
  }
}
