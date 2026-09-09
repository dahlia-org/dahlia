import { setTimeout as delay } from "node:timers/promises";
import type { AccountSettingsStore } from "../account-settings";
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
    private readonly settings: AccountSettingsStore,
  ) {}

  start(): void { this.running ??= this.run(); }

  async stop(): Promise<void> {
    this.abort.abort();
    await this.running;
  }

  private async run(): Promise<void> {
    let nextReconcile = 0;
    while (!this.abort.signal.aborted) {
      try {
        if (Date.now() >= nextReconcile) {
          nextReconcile = Date.now() + 60_000;
          await this.jobs.reconcile(this.captioner.model);
        }
        if (await this.processOne()) continue;
      } catch {
        console.warn(JSON.stringify({ level: "warn", event: "image_analysis_worker_failed" }));
      }
      await delay(1_000, undefined, { ref: false });
    }
  }

  processOne(): Promise<boolean> {
    return processImageAnalysisJob(this.jobs, this.captioner, this.syncStore, this.sync, this.settings, this.abort.signal);
  }
}
