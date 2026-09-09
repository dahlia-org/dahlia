import { setTimeout as delay } from "node:timers/promises";
import { personalWorkspaceId } from "../auth/workspace";
import type { MeetingSyncService } from "../sync/service";
import { SummaryError, type SummaryMethod, type SummaryStage } from "./model";
import type { SummaryJobStore } from "./store";

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
  async processOne(): Promise<boolean> {
    const job = await this.jobs.claim();
    if (!job) return false;
    const startedAt = Date.now();
    let phase: SummaryStage = job.stage ?? (job.method === "audio" ? "generating" : "summarizing");
    console.info(JSON.stringify({ level: "info", event: "summary_job_started", method: job.method, attempt: job.attempts }));
    try {
      const method = this.methods.find((method) => method.id === job.method);
      if (!method) throw new SummaryError("summary_method_unavailable");
      const signal = AbortSignal.any([this.abort.signal, AbortSignal.timeout(240_000)]);
      const identity = { userId: job.ownerUserId, workspaceId: personalWorkspaceId(job.ownerUserId), source: "accounts" as const };
      const advance = async (next: SummaryStage) => {
        signal.throwIfAborted();
        if (!await this.jobs.advance(job, next)) throw new SummaryError("summary_job_inactive");
        phase = next;
      };
      const twoStage = job.input?.type === "recording" && job.input.transcriptionModel !== undefined;
      if (twoStage && !job.transcriptResult) {
        if (!method.transcribe) throw new SummaryError("summary_method_unavailable");
        await advance("transcribing");
        const transcript = await method.transcribe(job, signal);
        await advance("saving");
        const saved = await this.sync.saveSummaryTranscript(identity, job, transcript, method);
        if (!saved) throw new SummaryError("summary_job_inactive");
        job.transcriptResult = { transcriptId: saved.id, version: String(saved.version) };
      }
      const generator = twoStage ? this.methods.find((method) => method.id === "transcript") : method;
      if (!generator) throw new SummaryError("summary_method_unavailable");
      await advance(twoStage || job.method === "transcript" ? "summarizing" : "generating");
      const document = await generator.generate(job, signal);
      await advance("saving");
      const saved = await this.sync.completeSummary({ userId: job.ownerUserId, workspaceId: personalWorkspaceId(job.ownerUserId), source: "accounts" }, job, document, method);
      console.info(JSON.stringify({ level: "info", event: saved ? "summary_job_succeeded" : "summary_job_lease_lost",
        attempt: job.attempts, durationMs: Date.now() - startedAt }));
    } catch (error) {
      const failure = error instanceof SummaryError ? error : new SummaryError("summary_processing_failed", true);
      console.warn(JSON.stringify({ level: "warn", event: "summary_job_failed", phase,
        code: /^[a-z0-9_]{1,80}$/.test(failure.code) ? failure.code : "summary_processing_failed",
        attempt: job.attempts, retryable: failure.retryable, requestId: failure.requestId,
        durationMs: Date.now() - startedAt }));
      await this.jobs.fail(job, failure.code, failure.retryable);
    }
    return true;
  }
}
