import type { SummaryJobStore } from "../summary/store";
import type { SummaryMethod } from "../summary/model";
import { processSummaryJob } from "../summary/process";
import type { ImageAnalysisQueueStore } from "../image-analysis/store";
import type { ImageCaptioner } from "../image-analysis/captioner";
import { processImageAnalysisJob } from "../image-analysis/process";
import type { SearchIndexQueueStore } from "../search/index-store";
import type { SearchEmbedder } from "../search/embedding";
import { processSearchIndexBatch } from "../search/process";
import type { MeetingSyncService } from "../sync/service";
import type { MeetingSyncStore } from "../sync/types";
import type { WorkspaceMemoryService } from "../memory/service";
import type { ChatMemoryService } from "../agent/context-service";
import { isRateLimited, RATE_LIMIT_COOLDOWN_MS } from "./rate-limit";
import type { BackgroundJob, JobStore } from "./store";
import type { JobKind } from "./model";
import { log } from "../otel/log";

export interface JobServices {
  queue: JobStore; summaryJobs: SummaryJobStore; methods: readonly SummaryMethod[];
  imageAnalysis?: ImageAnalysisQueueStore; captioner?: ImageCaptioner;
  searchIndex?: SearchIndexQueueStore; embedder?: SearchEmbedder;
  sync: MeetingSyncService; syncStore: MeetingSyncStore;
  memory?: WorkspaceMemoryService; personalMemory?: WorkspaceMemoryService; chatMemory?: ChatMemoryService;
}
export function createJobExecutor(services: JobServices) {
  const kinds: JobKind[] = ["maintenance", "storage-delete", "reconcile"];
  for (const method of services.methods) kinds.push(method.id === "audio" ? "audio-summary" : "summary");
  if (services.imageAnalysis && services.captioner) kinds.push("image");
  if (services.searchIndex && services.embedder) kinds.push("search");
  if (services.memory) kinds.push("workspace-memory");
  if (services.personalMemory) kinds.push("personal-memory");
  if (services.chatMemory) kinds.push("chat-memory");
  const cooldown = async (kind: JobKind, code?: string) => {
    if (code && isRateLimited(code)) await services.queue.cooldown(kind, Date.now() + RATE_LIMIT_COOLDOWN_MS);
  };
  async function execute(job: BackgroundJob & { batch: BackgroundJob[] }, signal: AbortSignal) {
    const payload = job.payload;

    switch (job.kind) {
      case "summary": case "audio-summary":
        await processSummaryJob({ ...services.summaryJobs, fail: async (claim, code, retryable) => {
          await services.summaryJobs.fail(claim, code, retryable); await cooldown(job.kind, code);
        } }, services.methods, services.sync, signal, job);
        break;
      case "image":
        await processImageAnalysisJob({ ...services.imageAnalysis!, finish: async (claim, error) => {
          await services.imageAnalysis!.finish(claim, error); await cooldown("image", error?.code);
        } }, services.captioner!, services.syncStore, services.sync, signal, job);
        break;
      case "search":
        await processSearchIndexBatch({ ...services.searchIndex!, retry: async (claim, code, at) => {
          await services.searchIndex!.retry(claim, code, at); await cooldown("search", code);
        } }, services.embedder!, signal, job.batch);
        break;
      case "workspace-memory": case "personal-memory":
        await (job.kind === "workspace-memory" ? services.memory! : services.personalMemory!).step(payload.scopeId!, signal, job);
        break;
      case "chat-memory": await services.chatMemory!.step(job.dedupeKey.slice("chat-memory:".length), payload.ownerUserId!, signal, job); break;
      case "storage-delete": await services.sync.drainStorageDeletes(payload.storageKey, job); break;
      case "maintenance": {
        const targets = await services.syncStore.listHistoryTargets(payload.after ? { workspaceId: payload.after } : undefined);
        for (const target of targets) {
          signal.throwIfAborted();
          await services.syncStore.purgeDeletedMeetings(target.workspaceId, new Date());
          await services.syncStore.expireRecordingUploads(target.workspaceId, new Date(Date.now() - 86_400_000));
        }
        const hasMore = targets.length === 100;
        await services.queue.reschedule(job, hasMore ? { after: targets.at(-1)!.workspaceId } : {}, hasMore ? 0 : 3_600_000);
        break;
      }
      case "reconcile": {
        const kind = payload.kind!;
        if ((kind === "image" && !services.captioner) || (kind === "search" && !services.embedder)) {
          await services.queue.reschedule(job, payload, 3_600_000); break;
        }
        if (payload.phase === "scopes") {
          const scopes = await services.queue.listScopes(kind, payload.after);
          for (const scopeId of scopes) await services.queue.enqueue(`reconcile:${kind}:${scopeId}`, "reconcile", scopeId,
            `reconcile:${kind}:${scopeId}`, { kind, phase: "page", scopeId });
          const hasMore = scopes.length === 100;
          await services.queue.reschedule(job, { kind, phase: "scopes", after: hasMore ? scopes.at(-1) : undefined }, hasMore ? 0 : 3_600_000);
        } else {
          const after = kind === "image" ? await services.imageAnalysis!.reconcilePage(services.captioner!.model, payload.scopeId!, payload.after)
            : await services.searchIndex!.reconcilePage(services.embedder!.model, services.embedder!.dimensions, payload.scopeId!, payload.after);
          if (after) await services.queue.reschedule(job, { ...payload, after }, 0);
        }
        break;
      }
    }
  }
  return {
    kinds,
    async processOne(signal: AbortSignal): Promise<boolean> {
      signal.throwIfAborted();
      const job = await services.queue.claim(kinds);
      if (!job) return false;
      const started = Date.now();
      try {
        await execute(job, AbortSignal.any([signal, AbortSignal.timeout(240_000)]));
        for (const item of job.batch) await services.queue.complete(item);
        log("info", "job_completed", { kind: job.kind, durationMs: Date.now() - started,
          waitMs: started - job.createdAt.getTime(), count: job.batch.length });
      } catch {
        // On shutdown, leave the lease until expiry: an interrupted upstream may still be running.
        if (!signal.aborted) for (const item of job.batch) await services.queue.retry(item);
        log("warn", "job_failed", { kind: job.kind });
      }
      return true;
    },
  };
}
