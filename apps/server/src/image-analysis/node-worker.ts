import { setTimeout as delay } from "node:timers/promises";
import type { MeetingSyncService } from "../sync/service";
import type { MeetingSyncStore } from "../sync/types";
import type { ImageCaptioner } from "./captioner";
import { processImageAnalysisJob } from "./process";
import type { ImageAnalysisStore } from "./store";

export class ImageAnalysisWorker {
  private readonly abort = new AbortController();
  private running?: Promise<void>;

  constructor(
    private readonly jobs: ImageAnalysisStore,
    private readonly captioner: ImageCaptioner,
    private readonly syncStore: MeetingSyncStore,
    private readonly sync: MeetingSyncService,
  ) {}

  start(): void { this.running ??= this.run(); }

  async stop(): Promise<void> {
    this.abort.abort();
    await this.running;
  }

  private async run(): Promise<void> {
    let nextReconcile = 0;
    let idleDelay = 1_000;
    while (!this.abort.signal.aborted) {
      try {
        if (Date.now() >= nextReconcile) {
          nextReconcile = Date.now() + 60_000;
          idleDelay = 1_000;
          await this.jobs.reconcile(this.captioner.model);
        }
        if (await this.processOne()) { idleDelay = 1_000; continue; }
      } catch {
        console.warn(JSON.stringify({ level: "warn", event: "image_analysis_worker_failed" }));
      }
      // Each idle claim checks every owner with due jobs, so back off until work or the next reconcile appears.
      await delay(Math.min(idleDelay, Math.max(0, nextReconcile - Date.now())), undefined, { ref: false });
      idleDelay = Math.min(idleDelay * 2, 30_000);
    }
  }

  processOne(): Promise<boolean> {
    return processImageAnalysisJob(this.jobs, this.captioner, this.syncStore, this.sync, this.abort.signal);
  }
}
