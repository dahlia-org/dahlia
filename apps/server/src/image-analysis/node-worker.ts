import { setTimeout as delay } from "node:timers/promises";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettingsStore } from "../account-settings";
import type { Identity } from "../auth/identity";
import { personalWorkspaceId } from "../auth/workspace";
import { ArtifactRequestError } from "../artifacts/service";
import type { MeetingSyncService } from "../sync/service";
import type { MeetingSyncStore } from "../sync/types";
import type { ImageCaptioner } from "./captioner";
import { ImageAnalysisError } from "./model";
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

  async processOne(): Promise<boolean> {
    const job = await this.jobs.claim(this.captioner.model);
    if (!job) return false;
    const identity: Identity = { userId: job.ownerUserId, workspaceId: personalWorkspaceId(job.ownerUserId), source: "accounts" };
    try {
      const input = await this.syncStore.withIdentity(identity, (scoped) => scoped.loadImageAnalysis(job));
      if (!input) {
        await this.jobs.finish(job);
        return true;
      }
      const settings = await this.settings.get(job.ownerUserId) ?? DEFAULT_ACCOUNT_SETTINGS;
      const { upstream } = await this.sync.readFileContent(identity, job.fileId, "thumb_1280", "GET",
        new Request("https://dahlia.invalid/", { signal: this.abort.signal }));
      if (!upstream.ok) {
        await upstream.body?.cancel();
        throw new ImageAnalysisError(`captioning_image_http_${upstream.status}`, upstream.status === 429 || upstream.status >= 500);
      }
      const bytes = new Uint8Array(await upstream.arrayBuffer());
      this.abort.signal.throwIfAborted();
      const analysis = await this.captioner.analyze(bytes, settings, this.abort.signal);
      this.abort.signal.throwIfAborted();
      if (!await this.sync.completeImageAnalysis(identity, input, analysis)) {
        await this.jobs.finish(job, { code: "stale_image", retryAt: new Date() });
      }
    } catch (error) {
      const failure = error instanceof ImageAnalysisError ? error
        : error instanceof ArtifactRequestError
          ? new ImageAnalysisError(`captioning_image_http_${error.status}`, error.status === 429 || error.status >= 500)
          : new ImageAnalysisError("captioning_processing_failed", true);
      await this.jobs.finish(job, {
        code: failure.code,
        retryAt: failure.retryable ? new Date(Date.now() + Math.min(15 * 60_000, 1_000 * 2 ** Math.min(job.attempts, 10))) : undefined,
      });
    }
    return true;
  }
}
