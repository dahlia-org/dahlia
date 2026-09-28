import { attachmentSchema, type ImageSettings } from "./images";
import { canonicalJson } from "../sync/service";
import { z } from "zod";
import type { AppConfig } from "../config";
import { DatabricksTokenProvider, tokenUntilAborted } from "../databricks/token";
import type { MemoryDocument } from "./model";
import { MEMORY_MISSION, PERSONAL_MEMORY_MISSION } from "./model";
import { reflectionResponseSchema } from "./reflection";
import { standardModel } from "./pages-model";

import { HindsightError } from "./errors";
export { HindsightError };
const operationSchema = z.object({ operation_id: z.string() });
const factSchema = z.object({ attachments: z.array(attachmentSchema).nullish(), id: z.string(), text: z.string(), type: z.string().nullish(), document_id: z.string().nullish(),
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
    if (!response.ok) { await response.body?.cancel(); throw new HindsightError(response.headers.get("x-dahlia-memory-error") === "memory_policy_blocked" ? "memory_policy_blocked" : "memory_upstream_failed", response.status); }
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
  async busy(bank: string, signal: AbortSignal) {
    for (const status of ["pending", "processing"]) {
      const result = z.object({ total: z.number().int().nonnegative() }).parse(await this.request(bank, `/operations?status=${status}&limit=1`, "GET", signal));
      if (result.total) return true;
    }
    return false;
  }
  async configuration(bank: string, signal: AbortSignal) {
    // Standard /config exposes configurable settings only, never credentials or bank resources.
    const result = z.object({ bank_id: z.string(), config: z.record(z.string(), z.unknown()) })
      .parse(await this.request(bank, "/config", "GET", signal));
    if (result.bank_id !== bank) throw new HindsightError("memory_ingestion_config_unavailable");
    return result.config;
  }
  async configure(bank: string, updates: Record<string, unknown>, signal: AbortSignal) {
    await this.request(bank, "/config", "PATCH", signal, { updates });
  }
  async extractionSettings(bank: string, mode: "concise" | "verbose", strategy: string | null, signal: AbortSignal) {
    await this.request(bank, "/config", "PATCH", signal, { updates: { retain_extraction_mode: mode, retain_default_strategy: strategy } });
  }
  async imageConfiguration(bank: string, settings: ImageSettings | undefined, signal: AbortSignal) {
    if (!settings) throw new HindsightError("memory_images_unconfigured");
    const raw = await this.request(bank, "/config", "GET", signal);
    const parsed = z.object({ bank_id: z.string(), dahlia_images: z.object({ provider: z.literal("databricks"), model: z.string(),
      enabled: z.literal(true), max_count: z.number(), max_bytes: z.number(), max_per_chunk: z.literal(1),
      max_completion_tokens: z.literal(4096), timeout: z.literal(60), retries: z.literal(0) }) }).safeParse(raw);
    if (!parsed.success || parsed.data.bank_id !== bank || parsed.data.dahlia_images.model !== settings.model
      || parsed.data.dahlia_images.max_count < settings.maxCount || parsed.data.dahlia_images.max_bytes < settings.maxBytes) {
      throw new HindsightError("memory_images_unconfigured");
    }
  }
  matchesImages(stored: Awaited<ReturnType<HindsightClient["document"]>>, document: MemoryDocument) {
    const images = document.source.images!;
    return !!stored && stored.original_text === document.retainedText && (stored.attachments?.length ?? 0) === new Set(images.entries.map((entry) => entry.hash)).size
      && images.entries.every((entry) => stored.attachments?.some((attachment) => attachment.id === entry.attachmentId
        && attachment.hash === entry.hash && attachment.byte_size === entry.bytes));
  }
  async ingestionPolicy(bank: string, signal: AbortSignal) {
    const result = z.object({ bank_id: z.string(), dahlia_ingestion_policy: z.string().regex(/^[0-9a-f]{64}$/) })
      .safeParse(await this.request(bank, "/config", "GET", signal));
    if (!result.success || result.data.bank_id !== bank) throw new HindsightError("memory_ingestion_config_unavailable");
    return result.data.dahlia_ingestion_policy;
  }
  async document(bank: string, id: string, signal: AbortSignal) {
    const raw = await this.request(bank, `/documents/${encodeURIComponent(id)}`, "GET", signal, undefined, true);
    if (raw === null) return null;
    const result = z.object({ id: z.string(), bank_id: z.string(), original_text: z.string().nullable(),
      attachments: z.array(attachmentSchema).nullish(), memory_unit_count: z.number().int().nonnegative(), retain_params: z.object({ metadata: z.record(z.string(), z.unknown()).optional() }).nullish() }).parse(raw);
    if (result.id !== id || result.bank_id !== bank) throw new HindsightError("memory_document_mismatch");
    return result;
  }
  async reprocess(bank: string, id: string, operationId: string, signal: AbortSignal) {
    const result = operationSchema.parse(await this.request(bank,
      `/documents/${encodeURIComponent(id)}/reprocess?operation_id=${encodeURIComponent(operationId)}`, "POST", signal));
    if (result.operation_id !== operationId) throw new HindsightError("memory_operation_mismatch");
  }
  async retain(bank: string, document: MemoryDocument, operationId: string, signal: AbortSignal, personal = false, policy?: string) {
    const tags = document.source.projectId ? [`project:${document.source.projectId}`] : [];
    const result = await this.request(bank, "/memories", "POST", signal, { async: true, operation_id: operationId,
      items: [{ content: document.retainContent ?? document.content, document_id: document.id, timestamp: document.timestamp,
        context: `${personal ? PERSONAL_MEMORY_MISSION : MEMORY_MISSION} Source kind: ${document.source.kind}.`,
        metadata: { ...(document.source.images ? { dahlia_image_manifest: canonicalJson(document.source.images), dahlia_images: "1" } : {}), ...(policy ? { dahlia_expected_ingestion_policy: policy } : {}), source_kind: document.source.kind, source_id: document.source.id, source_revision: document.source.revision },
        tags, observation_scopes: [[], ...(tags.length ? [tags] : [])], update_mode: "replace" }] });
    return operationSchema.parse(result).operation_id;
  }
  async operation(bank: string, id: string, signal: AbortSignal) {
    return (await this.operationDetail(bank, id, signal)).status;
  }
  async operationDetail(bank: string, id: string, signal: AbortSignal) {
    const result = await this.request(bank, `/operations/${encodeURIComponent(id)}`, "GET", signal, undefined, true);
    return result === null ? { status: "not_found" as const } : z.object({
      status: z.enum(["pending", "processing", "completed", "failed", "cancelled", "not_found"]),
      dahlia_error_code: z.literal("memory_policy_blocked").nullish(),
    }).parse(result);
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
    const definition = standardModel(projectId, personal);
    const { id, ...settings } = definition;
    // Reconcile existing settings too; a lost acknowledgement is recovered by GET + refresh.
    const existing = await this.request(bank, `/mental-models/${encodeURIComponent(id)}`, "GET", signal, undefined, true);
    if (existing) {
      await this.request(bank, `/mental-models/${encodeURIComponent(id)}`, "PATCH", signal, settings);
      return operationSchema.parse(await this.request(bank, `/mental-models/${encodeURIComponent(id)}/refresh`, "POST", signal)).operation_id;
    }
    return operationSchema.parse(await this.request(bank, "/mental-models", "POST", signal, definition)).operation_id;
  }
  async model(bank: string, id: string, signal: AbortSignal) {
    const raw = await this.request(bank, `/mental-models/${encodeURIComponent(id)}`, "GET", signal, undefined, true);
    if (raw === null) return null;
    return z.object({ id: z.string(), bank_id: z.string(), name: z.string(), source_query: z.string().nullable(),
      content: z.string().nullable(), tags: z.array(z.string()), max_tokens: z.number().nullable(),
      trigger: z.record(z.string(), z.unknown()).nullable(), last_refreshed_at: z.string().nullable(), is_stale: z.boolean().nullish(),
      reflect_response: z.object({ based_on: z.record(z.string(), z.array(z.object({ id: z.string(), text: z.string() }))),
        outcome: z.string().optional(), dahlia_generation: z.object({ cutoff: z.iso.datetime({ offset: true }), source_query: z.string(),
          tags: z.array(z.string()).nullable(), trigger: z.record(z.string(), z.unknown()), max_tokens: z.number().nullable() }).optional() }).nullable(),
    }).parse(raw);
  }
  async pageFact(bank: string, id: string, signal: AbortSignal) {
    const raw = await this.request(bank, `/memories/${encodeURIComponent(id)}`, "GET", signal, undefined, true);
    const parsed = z.object({ id: z.string(), text: z.string(), state: z.string(), type: z.string(), updated_at: z.iso.datetime({ offset: true }),
      document_id: z.string().nullish(), chunk_id: z.string().nullish(), attachments: z.array(attachmentSchema).nullish(), source_memory_ids: z.array(z.string()).default([]), metadata: z.record(z.string(), z.unknown()),
    }).safeParse(raw);
    return parsed.success && parsed.data.id === id && parsed.data.state === "valid" ? parsed.data : null;
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
  async factDocuments(bank: string, id: string, signal: AbortSignal, chunks?: Map<string, string[]>, validate?: (id: string, fact: { attachments?: z.infer<typeof attachmentSchema>[] | null; metadata?: Record<string, unknown> | null }) => Promise<boolean>): Promise<string[]> {
    const schema = z.object({ attachments: z.array(attachmentSchema).nullish(), metadata: z.record(z.string(), z.unknown()).nullish(), document_id: z.string().nullish(), chunk_id: z.string().nullish(), state: z.string(), source_memory_ids: z.array(z.string()).optional() });
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
      if (validate && !await validate(source.document_id!, source)) return [];
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
