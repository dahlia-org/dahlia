import { setTimeout as delay } from "node:timers/promises";
import type { MeetingSyncService } from "../sync/service";
import type { MeetingSyncStore } from "../sync/types";
import type { ImageCaptioner } from "./captioner";
import { processImageAnalysisJob } from "./process";
import type { ImageAnalysisStore } from "./store";

export class ImageAnalysisWorker {
  private readonly abort = new AbortController();
  private running?: Promise<void>;
  private nextReconcile = 0;

  constructor(
    private readonly jobs: ImageAnalysisStore,
    private readonly captioner: ImageCaptioner,
    private readonly syncStore: MeetingSyncStore,
    private readonly sync: MeetingSyncService,
    private readonly concurrency = 1,
  ) {}

  // Jobs wait on the model, not the CPU; each loop claims independently through leases.
  start(): void { this.running ??= Promise.all(Array.from({ length: this.concurrency }, () => this.run())).then(() => undefined); }

  async stop(): Promise<void> {
    this.abort.abort();
    await this.running;
  }

  private async run(): Promise<void> {
    let idleDelay = 1_000;
    while (!this.abort.signal.aborted) {
      try {
        // Commits enqueue jobs; this full scan only repairs missed or model-changed work.
        // Claimed before awaiting, so only one loop runs each reconcile.
        if (Date.now() >= this.nextReconcile) {
          this.nextReconcile = Date.now() + 60 * 60_000;
          idleDelay = 1_000;
          await this.jobs.reconcile(this.captioner.model);
        }
        if (await this.processOne()) { idleDelay = 1_000; continue; }
      } catch {
        console.warn(JSON.stringify({ level: "warn", event: "image_analysis_worker_failed" }));
      }
      // Each idle claim checks every owner with due jobs, so back off until work or the next reconcile appears.
      await delay(Math.min(idleDelay, Math.max(0, this.nextReconcile - Date.now())), undefined, { ref: false });
      idleDelay = Math.min(idleDelay * 2, 30_000);
    }
  }

  processOne(): Promise<boolean> {
    return processImageAnalysisJob(this.jobs, this.captioner, this.syncStore, this.sync, this.abort.signal);
  }
}
