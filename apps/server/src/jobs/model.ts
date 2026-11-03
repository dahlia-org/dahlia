import { z } from "zod";

export const jobKinds = ["summary", "audio-summary", "image", "search", "chat-memory", "storage-delete", "maintenance", "reconcile"] as const;
export type JobKind = typeof jobKinds[number];
export const jobGroups = ["summary", "audio", "image", "search", "chat", "storage"] as const;
export type JobGroup = typeof jobGroups[number];
export type JobLimits = Record<JobGroup, number>;
export const defaultJobLimits: JobLimits = { summary: 8, audio: 2, image: 4, search: 1, chat: 1, storage: 1 };
export const groupsForJob: Record<JobKind, readonly JobGroup[]> = {
  summary: ["summary"], "audio-summary": ["summary", "audio"], image: ["image"], search: ["search"],
  "chat-memory": ["chat"],
  "storage-delete": ["storage"], maintenance: ["storage"], reconcile: ["storage"],
};
export interface JobConfig { workers: "auto" | number; concurrency: "auto" | number; limits: JobLimits }
const autoNumber = (max = Number.MAX_SAFE_INTEGER) => z.union([z.literal("auto"), z.coerce.number().int().min(1).max(max)]);
export function loadJobConfig(env: Record<string, string | undefined>): JobConfig {
  // The retired Hindsight "memory" group may remain in deployed settings; ignore it so they still start.
  const limits: unknown = JSON.parse(env.DAHLIA_JOB_LIMITS || "{}");
  if (limits && typeof limits === "object") delete (limits as Record<string, unknown>).memory;
  return {
    workers: autoNumber().parse(env.DAHLIA_JOB_WORKERS?.trim() || "auto"),
    concurrency: autoNumber(8).parse(env.DAHLIA_JOB_CONCURRENCY?.trim() || "auto"),
    limits: { ...defaultJobLimits, ...z.partialRecord(z.enum(jobGroups), z.number().int().positive().max(Number.MAX_SAFE_INTEGER))
      .parse(limits) },
  };
}
export interface JobPayload { id?: string; ownerUserId?: string; workspaceId?: string; documentId?: string;
  dimensions?: number; mode?: "fill_missing" | "replace"; outputLanguage?: string | null;
  threadId?: string; messageId?: string | null; revision?: number; memoryKind?: "working" | "live"; fileId?: string; model?: string; scopeId?: string; storageKey?: string;
  after?: string; phase?: "scopes" | "page"; kind?: "image" | "search"; }
const id = z.uuid();
const summaryPayload = z.object({ id, ownerUserId: id, workspaceId: id });
export const jobPayloadSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("summary"), payload: summaryPayload }),
  z.object({ kind: z.literal("audio-summary"), payload: summaryPayload }),
  z.object({ kind: z.literal("image"), payload: z.object({ fileId: id, workspaceId: id, ownerUserId: id,
    model: z.string().min(1), mode: z.enum(["fill_missing", "replace"]), outputLanguage: z.string().nullable().optional() }) }),
  z.object({ kind: z.literal("search"), payload: z.object({ workspaceId: id, documentId: id,
    model: z.string().min(1), dimensions: z.number().int().min(32).max(1024) }) }),
  z.object({ kind: z.literal("storage-delete"), payload: z.object({ storageKey: z.string().min(1) }) }),
  z.object({ kind: z.literal("chat-memory"), payload: z.discriminatedUnion("memoryKind", [
    z.object({ memoryKind: z.literal("working"), threadId: z.string().min(1), ownerUserId: id,
      messageId: z.string().min(1), revision: z.number().int().nonnegative() }),
    z.object({ memoryKind: z.literal("live"), threadId: z.string().min(1), ownerUserId: id,
      revision: z.number().int().nonnegative() }),
  ]) }),
  z.object({ kind: z.literal("maintenance"), payload: z.object({ after: z.string().min(1).optional() }) }),
  z.object({ kind: z.literal("reconcile"), payload: z.discriminatedUnion("phase", [
    z.object({ phase: z.literal("scopes"), kind: z.enum(["image", "search"]), after: z.string().min(1).optional() }),
    z.object({ phase: z.literal("page"), kind: z.enum(["image", "search"]), scopeId: id, after: z.string().min(1).optional() }),
  ]) }),
]);
export const JOB_LEASE_MS = 300_000;
