import { z } from "zod";

export const jobKinds = ["summary", "audio-summary", "image", "search", "workspace-memory", "personal-memory", "chat-memory", "storage-delete", "maintenance", "reconcile"] as const;
export type JobKind = typeof jobKinds[number];
export const jobGroups = ["summary", "audio", "image", "search", "memory", "chat", "storage"] as const;
export type JobGroup = typeof jobGroups[number];
export type JobLimits = Record<JobGroup, number>;
export const defaultJobLimits: JobLimits = { summary: 8, audio: 2, image: 4, search: 1, memory: 1, chat: 1, storage: 1 };
export const groupsForJob: Record<JobKind, readonly JobGroup[]> = {
  summary: ["summary"], "audio-summary": ["summary", "audio"], image: ["image"], search: ["search"],
  "workspace-memory": ["memory"], "personal-memory": ["memory"], "chat-memory": ["chat"],
  "storage-delete": ["storage"], maintenance: ["storage"], reconcile: ["storage"],
};
export interface JobConfig { workers: "auto" | number; concurrency: "auto" | number; limits: JobLimits }
const autoNumber = (max = Number.MAX_SAFE_INTEGER) => z.union([z.literal("auto"), z.coerce.number().int().min(1).max(max)]);
export function loadJobConfig(env: Record<string, string | undefined>): JobConfig {
  return {
    workers: autoNumber().parse(env.DAHLIA_JOB_WORKERS?.trim() || "auto"),
    concurrency: autoNumber(8).parse(env.DAHLIA_JOB_CONCURRENCY?.trim() || "auto"),
    limits: { ...defaultJobLimits, ...z.partialRecord(z.enum(jobGroups), z.number().int().positive().max(Number.MAX_SAFE_INTEGER))
      .parse(JSON.parse(env.DAHLIA_JOB_LIMITS || "{}")) },
  };
}
export interface JobReference { id?: string; ownerUserId?: string; workspaceId?: string; documentId?: string;
  generation?: number; fileId?: string; model?: string; scopeId?: string; storageKey?: string;
  after?: string; phase?: "scopes" | "page"; kind?: "image" | "search"; }
export const JOB_LEASE_MS = 300_000;
