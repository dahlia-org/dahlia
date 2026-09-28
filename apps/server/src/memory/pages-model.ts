import { z } from "@hono/zod-openapi";
import { publicIdSchema } from "../agent/tools";
import type { MemorySource } from "./model";

export const pageIdSchema = z.string().regex(/^(workspace-insights|project-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/);
export const pageListSchema = z.object({ workspaceId: publicIdSchema("workspace"), projectId: publicIdSchema("project").optional(),
  query: z.string().trim().max(4000).optional(), after: pageIdSchema.optional() }).strict();
export const pageGetSchema = z.object({ workspaceId: publicIdSchema("workspace"), pageId: pageIdSchema }).strict();
export const pageStatusSchema = z.enum(["ready", "generating", "stale", "source_invalid", "paused", "unavailable", "error", "no_sources"]);
export type PageStatus = z.infer<typeof pageStatusSchema>;
export const pageSourceSchema = z.object({ kind: z.enum(["meeting", "shared"]), id: z.string(), revision: z.string(),
  href: z.string(), canonicalExcerpt: z.string(), truncated: z.boolean() });
export const pageSchema = z.object({ id: pageIdSchema, workspaceId: publicIdSchema("workspace"), projectId: publicIdSchema("project").nullable(),
  title: z.string(), status: pageStatusSchema, coverage: z.enum(["ready", "partial", "updating"]), skippedCount: z.number().int().nonnegative(),
  canRefresh: z.boolean(), generatedAt: z.string().nullable(), body: z.string().nullable(), snippet: z.string().nullable(),
  sources: z.array(pageSourceSchema), instruction: z.string() }).openapi("KnowledgePage");
export const pageListResultSchema = z.object({ items: z.array(pageSchema), nextCursor: pageIdSchema.nullable() }).openapi("KnowledgePageList");
export type KnowledgePage = z.infer<typeof pageSchema>;
export interface PageSnapshot {
  fingerprint: string;
  body: string;
  generatedAt: string;
  generationCutoff: string;
  conditions: ReturnType<typeof standardModel>;
  sources: Array<{ documentId: string; source: MemorySource; contentHash: string }>;
  facts: Array<{ id: string; hash: string; sourceIds: string[] }>;
}
export interface PageOperation { id: string; version: number; attempts: number }

// These are the existing models, not a second set of Knowledge Page generators.
export function standardModel(projectId: string | null, personal = false) {
  return {
    id: projectId ? `project-${projectId}` : "workspace-insights",
    name: projectId ? "Project decisions and open questions" : "Cross-meeting insights",
    source_query: personal ? "Find useful preferences, recurring lessons, decisions, changes and unresolved questions in this private memory. Cite source documents and preserve uncertainty." : projectId ? "What was decided, why, what changed, and what remains unresolved? Cite meeting evidence and dates."
      : "Across meetings, what recurring needs, obstacles, effective responses and exceptions appear? Cite distinct source meetings; do not count summaries as independent evidence or infer population statistics.",
    tags: projectId ? [`project:${projectId}`] : [], max_tokens: 2048,
    trigger: { mode: "full" as const, refresh_after_consolidation: true, min_refresh_interval_seconds: 3600,
      exclude_mental_models: true, tags_match: "all_strict" as const, reflect_search_observations_include_entities: false,
      // Upstream PATCH merges triggers: explicitly clear nonstandard overrides on existing models.
      fact_types: null, tag_groups: null, refresh_cron: null, exclude_mental_model_ids: null, include_chunks: null,
      recall_max_tokens: null, recall_chunks_max_tokens: null, reflect_search_observations_max_tokens: null,
      response_schema: null, keep_trace: false },
  };
}
