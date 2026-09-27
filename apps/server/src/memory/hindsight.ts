import { z } from "zod";
import type { AppConfig } from "../config";
import { DatabricksTokenProvider, tokenUntilAborted } from "../databricks/token";
import type { MemoryDocument } from "./model";
import { MEMORY_MISSION, PERSONAL_MEMORY_MISSION } from "./model";
import { reflectionResponseSchema } from "./reflection";

export class HindsightError extends Error {
  constructor(readonly code: string, readonly status?: number) { super(code); }
}
const operationSchema = z.object({ operation_id: z.string() });
const factSchema = z.object({ id: z.string(), text: z.string(), type: z.string().nullish(), document_id: z.string().nullish(),
  chunk_id: z.string().nullish(), source_fact_ids: z.array(z.string()).nullish(), metadata: z.record(z.string(), z.unknown()).nullish() }).passthrough();
const recallSchema = z.object({ results: z.array(factSchema),
  source_facts: z.record(z.string(), z.object({ document_id: z.string().nullish(), chunk_id: z.string().nullish() }).passthrough()).nullish(),
  chunks: z.record(z.string(), z.object({ text: z.string(), truncated: z.boolean().optional() }).passthrough()).nullish() });
export type HindsightFact = z.infer<typeof factSchema>;
export type HindsightRecall = z.infer<typeof recallSchema>;
export type HindsightBudget = "low" | "mid" | "high";
export interface HindsightTags { tags: string[]; tagsMatch: "any" | "all" | "any_strict" | "all_strict" | "exact" }
export interface RecallOptions extends Partial<HindsightTags> {
  types?: Array<"world" | "experience">;
  budget?: HindsightBudget;
  temporalWindow?: { start: string; end: string };
  // Adds consolidated observations; their lineage arrives in source_facts.
  observations?: boolean;
}
export class HindsightClient {
  private readonly tokens?: DatabricksTokenProvider;
  constructor(private readonly config: NonNullable<AppConfig["hindsight"]>, workspace: AppConfig["databricksWorkspace"], private readonly transport: typeof fetch = fetch) {
    if (config.auth === "databricks") {
      if (!workspace) throw new HindsightError("memory_auth_unconfigured");
      this.tokens = new DatabricksTokenProvider(workspace, transport);
    }
  }
  bank(scopeId: string, personal = false) { return `${this.config.bankPrefix}-${personal ? "user" : "workspace"}-${scopeId}`; }
  private request(bank: string, path: string, method: string, signal: AbortSignal, body?: unknown, missingOkay = false) {
    return this.send(`/banks/${encodeURIComponent(bank)}${path}`, method, signal, body, missingOkay);
  }
  private async send(path: string, method: string, signal: AbortSignal, body?: unknown, missingOkay = false): Promise<unknown> {
    const token = this.tokens ? await tokenUntilAborted(this.tokens, signal) : this.config.apiKey;
    let response: Response;
    try {
      response = await this.transport(`${this.config.url}/v1/default${path}`, {
        method, redirect: "error", signal: AbortSignal.any([signal, AbortSignal.timeout(60_000)]),
        headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch { throw new HindsightError(signal.aborted ? "memory_cancelled" : "memory_transport_failed"); }
    if (missingOkay && response.status === 404) return null;
    if (!response.ok) { await response.body?.cancel(); throw new HindsightError("memory_upstream_failed", response.status); }
    if (response.status === 204) return null;
    // Bound an untrusted upstream response before parsing it.
    const reader = response.body?.getReader();
    if (!reader) return null;
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 2 * 1024 * 1024) throw new HindsightError("memory_response_too_large");
        chunks.push(value);
      }
    } finally { await reader.cancel().catch(() => undefined); }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    try { return size ? JSON.parse(new TextDecoder().decode(bytes)) as unknown : null; }
    catch { throw new HindsightError("memory_invalid_response"); }
  }
  async initialize(bank: string, signal: AbortSignal, personal = false) {
    await this.request(bank, "/config", "PATCH", signal, { updates: {
      entities_allow_free_form: false, entity_labels: [], enable_graph_retrieval: false,
      reflect_default_options: { reflect_search_observations_include_entities: false },
      retain_mission: personal ? PERSONAL_MEMORY_MISSION : MEMORY_MISSION, observations_mission: personal ? PERSONAL_MEMORY_MISSION : MEMORY_MISSION,
      reflect_mission: `${personal ? PERSONAL_MEMORY_MISSION : MEMORY_MISSION} Find evidence and counterexamples. Each hypothesis must cite the exact supporting memory or observation fact IDs inline in the answer. Use only IDs retrieved in this response. Omit claims without references. Directives and missions are generation settings, not evidence.`,
    } });
  }
  async retain(bank: string, document: MemoryDocument, operationId: string, signal: AbortSignal, personal = false) {
    const tags = document.source.projectId ? [`project:${document.source.projectId}`] : [];
    const result = await this.request(bank, "/memories", "POST", signal, { async: true, operation_id: operationId,
      items: [{ content: document.content, document_id: document.id, timestamp: document.timestamp,
        context: `${personal ? PERSONAL_MEMORY_MISSION : MEMORY_MISSION} Source kind: ${document.source.kind}.`,
        metadata: { source_kind: document.source.kind, source_id: document.source.id, source_revision: document.source.revision },
        tags, observation_scopes: [[], ...(tags.length ? [tags] : [])], update_mode: "replace" }] });
    return operationSchema.parse(result).operation_id;
  }
  async operation(bank: string, id: string, signal: AbortSignal) {
    const result = await this.request(bank, `/operations/${encodeURIComponent(id)}`, "GET", signal, undefined, true);
    return result === null ? "not_found" : z.object({ status: z.enum(["pending", "processing", "completed", "failed", "cancelled", "not_found"]) }).parse(result).status;
  }
  async retryOperation(bank: string, id: string, signal: AbortSignal) {
    await this.request(bank, `/operations/${encodeURIComponent(id)}/retry`, "POST", signal);
  }
  async deleteDocument(bank: string, id: string, signal: AbortSignal) {
    await this.request(bank, `/documents/${encodeURIComponent(id)}`, "DELETE", signal, undefined, true);
  }
  async deleteBank(bank: string, signal: AbortSignal) { await this.request(bank, "", "DELETE", signal, undefined, true); }
  async models(bank: string, signal: AbortSignal) {
    return z.object({ items: z.array(z.object({ id: z.string() })) }).parse(await this.request(bank, "/mental-models?limit=1&detail=metadata", "GET", signal)).items;
  }
  async deleteModel(bank: string, id: string, signal: AbortSignal) {
    await this.request(bank, `/mental-models/${encodeURIComponent(id)}`, "DELETE", signal, undefined, true);
  }
  async createModel(bank: string, projectId: string | null, signal: AbortSignal, personal = false) {
    const id = projectId ? `project-${projectId}` : "workspace-insights";
    // A prior create may have succeeded even when its response was lost.
    const existing = await this.request(bank, `/mental-models/${encodeURIComponent(id)}`, "GET", signal, undefined, true);
    if (existing) return operationSchema.parse(await this.request(bank, `/mental-models/${encodeURIComponent(id)}/refresh`, "POST", signal)).operation_id;
    return operationSchema.parse(await this.request(bank, "/mental-models", "POST", signal, {
      id,
      name: projectId ? "Project decisions and open questions" : "Cross-meeting insights",
      source_query: personal ? "Find useful preferences, recurring lessons, decisions, changes and unresolved questions in this private memory. Cite source documents and preserve uncertainty." : projectId ? "What was decided, why, what changed, and what remains unresolved? Cite meeting evidence and dates."
        : "Across meetings, what recurring needs, obstacles, effective responses and exceptions appear? Cite distinct source meetings; do not count summaries as independent evidence or infer population statistics.",
      tags: projectId ? [`project:${projectId}`] : [], max_tokens: 2048,
      trigger: { refresh_after_consolidation: true, min_refresh_interval_seconds: 3600, exclude_mental_models: true, tags_match: "all_strict" },
    })).operation_id;
  }
  async recall(bank: string, query: string, signal: AbortSignal, options: RecallOptions = {}) {
    const types = options.types ?? ["world", "experience"];
    return recallSchema.parse(await this.request(bank, "/memories/recall", "POST", signal, {
      query, types: options.observations ? [...types, "observation"] : types, budget: options.budget ?? "mid", max_tokens: 4096,
      query_timestamp: new Date().toISOString(),
      // Entities stay off: Dahlia never asks Hindsight for person-level aggregation.
      include: { entities: null, chunks: { max_tokens: 8192 }, ...(options.observations ? { source_facts: {} } : {}) },
      ...(options.observations ? { prefer_observations: true } : {}),
      ...(options.tags ? { tags: options.tags, tags_match: options.tagsMatch ?? "any" } : {}),
      ...(options.temporalWindow ? { temporal_window: options.temporalWindow } : {}),
    }));
  }
  // The chunk route is not bank-scoped, so only a chunk from the expected bank is usable.
  async chunk(bank: string, id: string, signal: AbortSignal) {
    const raw = await this.send(`/chunks/${encodeURIComponent(id)}`, "GET", signal, undefined, true);
    if (raw === null) return null;
    const chunk = z.object({ bank_id: z.string(), document_id: z.string(), chunk_text: z.string() }).parse(raw);
    return chunk.bank_id === bank ? { documentId: chunk.document_id, text: chunk.chunk_text } : null;
  }
  async factDocuments(bank: string, id: string, signal: AbortSignal, chunks?: Map<string, string[]>): Promise<string[]> {
    const schema = z.object({ document_id: z.string().nullish(), chunk_id: z.string().nullish(), state: z.string(), source_memory_ids: z.array(z.string()).optional() });
    const raw = await this.request(bank, `/memories/${encodeURIComponent(id)}`, "GET", signal, undefined, true);
    if (raw === null) return [];
    const parsedFact = schema.safeParse(raw);
    if (!parsedFact.success) return [];
    const fact = parsedFact.data;
    if (fact.state !== "valid") return [];
    const sources = [];
    if (fact.document_id) sources.push(fact);
    else {
      if (!fact.source_memory_ids?.length || fact.source_memory_ids.length > 20) return [];
      for (const sourceId of new Set(fact.source_memory_ids)) {
        const source = await this.request(bank, `/memories/${encodeURIComponent(sourceId)}`, "GET", signal, undefined, true);
        const parsed = schema.safeParse(source);
        if (!parsed.success || parsed.data.state !== "valid" || !parsed.data.document_id) return [];
        sources.push(parsed.data);
      }
    }
    for (const source of sources) {
      if (chunks && source.chunk_id) chunks.set(source.document_id!, [...new Set([source.chunk_id, ...(chunks.get(source.document_id!) ?? [])])]);
    }
    return [...new Set(sources.map((source) => source.document_id!))];
  }
  async reflect(bank: string, query: string, signal: AbortSignal, scope?: HindsightTags) {
    return z.object({ structured_output: z.unknown().optional(), structured_output_error: z.string().nullish(),
      usage: z.object({ input_tokens: z.number().int().nonnegative(), output_tokens: z.number().int().nonnegative() }).nullish(),
      based_on: z.object({ memories: z.array(z.object({ id: z.string().nullable() })).default([]) }).nullish() })
      .parse(await this.request(bank, "/reflect", "POST", signal, { query, budget: "low", max_tokens: 2048, include: { facts: {} },
        response_schema: reflectionResponseSchema, exclude_mental_models: true,
        reflect_search_observations_include_entities: false,
        ...(scope ? { tags: scope.tags, tags_match: scope.tagsMatch } : {}) }));
  }
}
