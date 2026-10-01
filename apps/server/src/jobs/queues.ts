import { z } from "zod";
import type { ChatMemoryService } from "../agent/context-service";
import type { WorkspaceMemoryService } from "../memory/service";
import type { MeetingSyncStore } from "../sync/types";
import type { MeetingSyncService } from "../sync/service";
import type { SummaryMethod } from "../summary/model";
import type { SummaryJobStore } from "../summary/store";
import type { ImageAnalysisQueueStore } from "../image-analysis/store";
import type { ImageCaptioner } from "../image-analysis/captioner";
import type { SearchIndexQueueStore } from "../search/index-store";
import type { SearchEmbedder } from "../search/embedding";
import type { JobStore } from "./store";
import { createJobExecutor } from "./execute";

export const jobMessageSchema = z.object({ action: z.literal("wake") }).strict();
export type JobMessage = z.infer<typeof jobMessageSchema>;
export interface JobQueue {
  send(body: JobMessage, options?: { delaySeconds: number }): Promise<unknown>;
  sendBatch(messages: { body: JobMessage }[]): Promise<unknown>;
}
export interface WorkerJobBindings { DAHLIA_JOB_QUEUE?: JobQueue }
export interface WorkerJobStores {
  queue: JobStore;
  summaryJobs: SummaryJobStore;
  imageAnalysis: ImageAnalysisQueueStore;
  searchIndex: SearchIndexQueueStore;
}
export function createQueueJobs(bindings: WorkerJobBindings, stores: WorkerJobStores,
  syncStore: MeetingSyncStore, sync: MeetingSyncService, methods: readonly SummaryMethod[],
  captioner?: ImageCaptioner, embedder?: SearchEmbedder, memory?: WorkspaceMemoryService,
  chatMemory?: ChatMemoryService, personalMemory?: WorkspaceMemoryService, concurrency = 4) {
  const executor = createJobExecutor({ ...stores, methods, syncStore, sync, captioner, embedder, memory, chatMemory, personalMemory });
  const notify = async () => {
    try { await bindings.DAHLIA_JOB_QUEUE?.send({ action: "wake" }); }
    catch { console.warn(JSON.stringify({ event: "job_notification_failed" })); }
  };
  return {
    notify,
    async schedule() { await stores.queue.scheduleMaintenance(); await notify(); },
    async consume(body: unknown, signal: AbortSignal) {
      jobMessageSchema.parse(body);
      if (!bindings.DAHLIA_JOB_QUEUE) throw new Error("job_queue_unavailable");
      const results = await Promise.allSettled(Array.from({ length: concurrency }, () => executor.processOne(signal)));
      const failure = results.find((result) => result.status === "rejected");
      if (failure) throw failure.reason;
      // The DB remains authoritative if this hint fails; minute cron retries missed and delayed work.
      const delaySeconds = await stores.queue.nextDelay(executor.kinds);
      // Cron owns longer waits; chaining hourly maintenance hints forever would multiply idle polling.
      if (delaySeconds !== undefined && delaySeconds < 60) await bindings.DAHLIA_JOB_QUEUE.send({ action: "wake" }, { delaySeconds });
    },
  };
}
