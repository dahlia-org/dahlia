import { z } from "zod";
import type { AccountSettingsStore } from "../account-settings";
import type { MeetingSyncStore } from "../sync/types";
import type { MeetingSyncService } from "../sync/service";
import type { SummaryMethod } from "../summary/model";
import type { SummaryJobQueueStore } from "../summary/store";
import { processSummaryJob } from "../summary/process";
import type { ImageAnalysisQueueStore } from "../image-analysis/store";
import type { ImageCaptioner } from "../image-analysis/captioner";
import { processImageAnalysisJob } from "../image-analysis/process";
import type { SearchIndexQueueStore } from "../search/index-store";
import type { SearchEmbedder } from "../search/embedding";
import { processSearchIndexBatch } from "../search/process";

const kind = z.enum(["summary", "image", "search"]);
const ownerUserId = z.string().min(1).max(500);
const id = z.uuid();
const cursor = z.union([id, z.string().regex(/^[0-9a-f-]{36}\/[0-9a-f-]{36}$/)]);
const scan = z.object({ action: z.literal("scan"), kind, ownerUserId,
  phase: z.enum(["reconcile", "dispatch"]), after: cursor.optional() }).strict();
export const jobMessageSchema = z.union([
  z.object({ action: z.literal("owners"), kind, afterOwner: ownerUserId.optional() }).strict(),
  scan.refine((value) => !value.after || (value.kind === "search") === value.after.includes("/")),
  z.object({ action: z.literal("run"), kind: z.literal("summary"),
    reference: z.object({ id, ownerUserId }).strict() }).strict(),
  z.object({ action: z.literal("run"), kind: z.literal("image"),
    reference: z.object({ fileId: id, ownerUserId, model: z.string().min(1).max(200) }).strict() }).strict(),
  z.object({ action: z.literal("run"), kind: z.literal("search"), references: z.array(z.object({
    vaultId: id, documentId: id, ownerUserId, generation: z.number().int().positive(),
  }).strict()).min(1).max(16) }).strict(),
]);
export type JobMessage = z.infer<typeof jobMessageSchema>;
type JobKind = z.infer<typeof kind>;

export interface JobQueue {
  send(body: JobMessage): Promise<unknown>;
  sendBatch(messages: { body: JobMessage }[]): Promise<unknown>;
}
export interface WorkerJobBindings {
  DAHLIA_SUMMARY_QUEUE?: JobQueue;
  DAHLIA_IMAGE_QUEUE?: JobQueue;
  DAHLIA_SEARCH_QUEUE?: JobQueue;
}
export interface WorkerJobStores {
  summaryJobs: SummaryJobQueueStore;
  imageAnalysis: ImageAnalysisQueueStore;
  searchIndex: SearchIndexQueueStore;
  listJobOwners(after?: string): Promise<string[]>;
}

export function createQueueJobs(bindings: WorkerJobBindings, stores: WorkerJobStores,
  syncStore: MeetingSyncStore, sync: MeetingSyncService, accountSettings: AccountSettingsStore,
  methods: readonly SummaryMethod[], captioner?: ImageCaptioner, embedder?: SearchEmbedder) {
  const queues = {
    summary: methods.length ? bindings.DAHLIA_SUMMARY_QUEUE : undefined,
    image: captioner ? bindings.DAHLIA_IMAGE_QUEUE : undefined,
    search: embedder ? bindings.DAHLIA_SEARCH_QUEUE : undefined,
  };
  const scanMessage = (kind: JobKind, ownerUserId: string): JobMessage => ({
    kind, action: "scan", ownerUserId, phase: kind === "summary" ? "dispatch" : "reconcile",
  });
  return {
    async notify(ownerUserId: string) {
      // This is a post-commit hint. Cron recovers a failed send from the canonical job tables.
      const results = await Promise.allSettled(Object.entries(queues).map(([kind, queue]) =>
        queue?.send(scanMessage(kind as JobKind, ownerUserId)) ?? Promise.resolve()));
      if (results.some((result) => result.status === "rejected")) {
        console.warn(JSON.stringify({ level: "warn", event: "job_notification_failed" }));
      }
    },
    async schedule() {
      const results = await Promise.allSettled(Object.entries(queues).map(([kind, queue]) =>
        queue?.send({ kind: kind as JobKind, action: "owners" }) ?? Promise.resolve()));
      const failure = results.find((result) => result.status === "rejected");
      if (failure) throw failure.reason;
    },
    async consume(body: unknown, signal: AbortSignal) {
      const message = jobMessageSchema.parse(body);
      const queue = queues[message.kind];
      if (!queue) throw new Error("job_queue_unavailable");
      signal.throwIfAborted();
      if (message.action === "owners") {
        const owners = await stores.listJobOwners(message.afterOwner);
        if (owners.length) await queue.sendBatch(owners.map((owner) => ({ body: scanMessage(message.kind, owner) })));
        if (owners.length === 100) await queue.send({ ...message, afterOwner: owners.at(-1)! });
        return;
      }
      if (message.action === "scan") {
        if (message.phase === "reconcile") {
          let after: string | undefined;
          if (message.kind === "image") {
            after = await stores.imageAnalysis.reconcilePage(captioner!.model, message.ownerUserId, message.after);
          } else if (message.kind === "search") {
            after = await stores.searchIndex.reconcilePage(embedder!.model, embedder!.dimensions, message.ownerUserId, message.after);
          }
          await queue.send({ ...message, after, phase: after ? "reconcile" : "dispatch" });
          return;
        }
        let messages: JobMessage[];
        let count: number;
        let after: string | undefined;
        if (message.kind === "summary") {
          const rows = await stores.summaryJobs.due(message.ownerUserId, message.after);
          messages = rows.map((reference) => ({ action: "run", kind: "summary", reference }));
          count = rows.length;
          after = rows.at(-1)?.id;
        } else if (message.kind === "image") {
          const rows = await stores.imageAnalysis.due(captioner!.model, message.ownerUserId, message.after);
          messages = rows.map((reference) => ({ action: "run", kind: "image", reference }));
          count = rows.length;
          after = rows.at(-1)?.fileId;
        } else {
          const rows = await stores.searchIndex.due(embedder!.model, embedder!.dimensions, message.ownerUserId, message.after);
          messages = [];
          for (let offset = 0; offset < rows.length; offset += 16) {
            messages.push({ action: "run", kind: "search", references: rows.slice(offset, offset + 16) });
          }
          const last = rows.at(-1);
          count = rows.length;
          after = last ? `${last.documentId}/${last.vaultId}` : undefined;
        }
        if (messages.length) await queue.sendBatch(messages.map((body) => ({ body })));
        if (count === 100) await queue.send({ ...message, after });
        return;
      }
      if (message.kind === "summary") {
        await processSummaryJob(stores.summaryJobs, methods, sync, signal, message.reference);
      } else if (message.kind === "image") {
        await processImageAnalysisJob(stores.imageAnalysis, captioner!, syncStore, sync, accountSettings, signal, message.reference);
      } else {
        await processSearchIndexBatch(stores.searchIndex, embedder!, signal, message.references);
      }
      // A generated summary, transcript, or caption can invalidate a search document.
      if (message.kind !== "search" && queues.search) {
        await queues.search.send(scanMessage("search", message.reference.ownerUserId));
      }
    },
  };
}
