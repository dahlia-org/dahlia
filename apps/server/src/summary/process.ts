import type { MeetingSyncService } from "../sync/service";
import { SummaryError, type SummaryMethod, type SummaryStage } from "./model";
import type { SummaryJobReference, SummaryJobStore } from "./store";

export async function processSummaryJob(
  jobs: SummaryJobStore, methods: readonly SummaryMethod[], sync: MeetingSyncService,
  abortSignal: AbortSignal, reference?: SummaryJobReference,
): Promise<boolean> {
  const job = await jobs.claim(reference);
  if (!job) return false;
  const startedAt = Date.now();
  let phase: SummaryStage = job.stage ?? (job.method === "audio" ? "generating" : "summarizing");
  console.info(JSON.stringify({ level: "info", event: "summary_job_started", method: job.method, attempt: job.attempts }));
  const signal = AbortSignal.any([abortSignal, AbortSignal.timeout(240_000)]);
  const processingFailure = (error: unknown): never => {
    throw error instanceof SummaryError ? error : new SummaryError("summary_processing_failed", true);
  };
  try {
    const method = methods.find((method) => method.id === job.method);
    if (!method) throw new SummaryError("summary_method_unavailable");
    const identity = { userId: job.ownerUserId, source: "accounts" as const };
    const advance = async (next: SummaryStage) => {
      signal.throwIfAborted();
      if (!await jobs.advance(job, next)) throw new SummaryError("summary_job_inactive");
      phase = next;
    };
    const twoStage = job.input?.type === "recording" && job.input.transcriptionModel !== undefined;
    if (twoStage && !job.transcriptResult) {
      if (!method.transcribe) throw new SummaryError("summary_method_unavailable");
      await advance("transcribing");
      const transcript = await method.transcribe(job, signal).catch(processingFailure);
      await advance("saving");
      const saved = await sync.saveSummaryTranscript(identity, job, transcript, method);
      if (!saved) throw new SummaryError("summary_job_inactive");
      job.transcriptResult = { transcriptId: saved.id, version: String(saved.version) };
    }
    const generator = twoStage ? methods.find((method) => method.id === "transcript") : method;
    if (!generator) throw new SummaryError("summary_method_unavailable");
    await advance(twoStage || job.method === "transcript" ? "summarizing" : "generating");
    const document = await generator.generate(job, signal).catch(processingFailure);
    await advance("saving");
    const saved = await sync.completeSummary({ userId: job.ownerUserId, source: "accounts" }, job, document, method);
    console.info(JSON.stringify({ level: "info", event: saved ? "summary_job_succeeded" : "summary_job_lease_lost",
      attempt: job.attempts, durationMs: Date.now() - startedAt }));
  } catch (error) {
    if (!(error instanceof SummaryError) && !signal.aborted) throw error;
    const failure = error instanceof SummaryError ? error : new SummaryError("summary_processing_failed", true);
    console.warn(JSON.stringify({ level: "warn", event: "summary_job_failed", phase,
      code: /^[a-z0-9_]{1,80}$/.test(failure.code) ? failure.code : "summary_processing_failed",
      attempt: job.attempts, retryable: failure.retryable, requestId: failure.requestId,
      durationMs: Date.now() - startedAt }));
    await jobs.fail(job, failure.code, failure.retryable);
  }
  return true;
}
