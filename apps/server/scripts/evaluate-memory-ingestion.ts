/** Operator-only harness. Never imported by routes, tools or the package entrypoint.
 * Uses isolated banks and the production search/publication pipeline, with a transient
 * ingestion ledger. The supplied store remains the authorized canonical read source.
 */
import { setTimeout } from "node:timers/promises";
import type { z } from "zod";
import type { AppConfig } from "../src/config";
import type { Identity } from "../src/auth/identity";
import type { MeetingSyncService } from "../src/sync/service";
import type { MeetingSyncStore } from "../src/sync/types";
import type { MemoryStore } from "../src/memory/store";
import { WorkspaceMemoryService } from "../src/memory/service";
import { HindsightError } from "../src/memory/hindsight";
import { ingestionFingerprint, ingestionPolicy } from "../src/memory/ingestion";
import { contentHash, meetingDocument, noteDocument } from "../src/memory/sources";
import type { MemoryDocument } from "../src/memory/model";
import { uuidV7 } from "../src/id";
import { encodeId } from "../src/typeid";
import { evaluateMemory, type questionsSchema } from "./evaluate-memory";

export async function compareMemoryIngestion(input: {
  config: AppConfig; store: MemoryStore; sync: MeetingSyncService; syncStore: MeetingSyncStore;
  identity: Identity; scopeId: string; questions: z.infer<typeof questionsSchema>;
  strategies?: string[]; reflect?: boolean; signal: AbortSignal; transport?: typeof fetch;
  poll?: (signal: AbortSignal) => Promise<void>;
}) {
  const { config, store, sync, syncStore, identity, scopeId } = input;
  const signal = AbortSignal.any([input.signal, AbortSignal.timeout(30 * 60_000)]);
  const poll = input.poll ?? ((signal: AbortSignal) => setTimeout(1000, undefined, { signal }));
  const production = new WorkspaceMemoryService(config, store, sync, syncStore, input.transport);
  const initial = await store.status(identity.userId, scopeId);
  if (!initial?.enabled || initial.purge || !await production.policyCurrent(initial, signal)) throw new Error("memory_evaluation_not_ready");
  const settings = await production.client.configuration(initial.bankId, signal);
  const documents: MemoryDocument[] = [];
  const assemblyFailures: Record<string, string> = {};
  const loadMeeting = async (id: string) => {
    try { return await meetingDocument(sync, identity, scopeId, id, signal); }
    catch (error) {
      signal.throwIfAborted();
      if (!(error instanceof HindsightError) || error.code !== "memory_source_too_large") throw error;
      assemblyFailures[`meeting-${id}`] = error.code;
      return null;
    }
  };
  if (!store.personal) {
    let cursor: { createdAt: Date; meetingId: string } | undefined;
    for (;;) {
      signal.throwIfAborted();
      const rows = await syncStore.withIdentity(identity, (scoped) => scoped.listMeetings(scopeId, undefined, 100, undefined, cursor));
      for (const row of rows) {
        const document = await loadMeeting(row.meetingId);
        if (document) documents.push(document);
      }
      if (rows.length < 100) break;
      cursor = { createdAt: rows.at(-1)!.createdAt, meetingId: rows.at(-1)!.meetingId };
    }
  }
  let after: string | undefined;
  do {
    signal.throwIfAborted();
    const rows = await store.listNotes(identity.userId, scopeId, after);
    documents.push(...rows.map((note) => noteDocument(note, store.personal)));
    after = rows.length === 100 ? rows.at(-1)!.id : undefined;
  } while (after);
  const variants = [ { mode: "concise" as const, strategy: null as string | null }, { mode: "verbose" as const, strategy: null as string | null },
    ...[...new Set(input.strategies ?? [])].map((strategy) => ({ mode: "concise" as const, strategy })) ];
  const results = [];
  for (const variant of variants) {
    signal.throwIfAborted();
    const evaluationConfig = { ...config, hindsight: { ...config.hindsight!, bankPrefix: `eval-${uuidV7()}` } };
    const ledger = new Map<string, NonNullable<Awaited<ReturnType<MemoryStore["document"]>>>>();
    const failures: Record<string, string> = { ...assemblyFailures };
    let policy = "", upstream = "";
    // All authorization and canonical reads remain live; only the derived ledger is isolated.
    const readStore: MemoryStore = { ...store, document: (_, id) => Promise.resolve(ledger.get(id)), pending: () => Promise.resolve(undefined),
      status: async (user, scope) => {
        const current = await store.status(user, scope);
        if (!current) return null;
        return { ...current, bankId: engine.client.bank(scopeId, store.personal), indexedGeneration: initial.generation,
          reconcile: current.generation !== initial.generation, progress: { ...current.progress!, ingestionPolicy: policy,
            upstreamPolicy: upstream, failures } };
      } };
    const engine = new WorkspaceMemoryService(evaluationConfig, readStore, sync, syncStore, input.transport);
    const bank = engine.client.bank(scopeId, store.personal);
    const wait = async (bankId: string, operation: string) => {
      for (;;) {
        signal.throwIfAborted();
        const detail = await engine.client.operationDetail(bankId, operation, signal);
        if (detail.status === "completed") return;
        if (!["pending", "processing"].includes(detail.status)) throw new HindsightError(detail.dahlia_error_code ?? "memory_operation_failed");
        await poll(signal);
      }
    };
    try {
      // Copy settings only: upstream bank clone also copies webhooks/directives and queues work on the source.
      await engine.client.configure(bank, settings, signal);
      await engine.client.extractionSettings(bank, variant.mode, variant.strategy, signal);
      upstream = await engine.client.ingestionPolicy(bank, signal); policy = await ingestionPolicy(upstream);
      for (const document of documents) {
        const live = document.source.kind === "meeting" ? await loadMeeting(document.source.id)
          : await store.getNote(identity.userId, scopeId, document.source.id).then((note) => note ? noteDocument(note, store.personal) : null);
        if (!live || live.source.revision !== document.source.revision || await contentHash(live.content) !== await contentHash(document.content)) {
          failures[document.id] = assemblyFailures[document.id] ?? "memory_source_changed"; continue;
        }
        try {
          const operation = uuidV7();
          await engine.client.retain(bank, document, operation, signal, store.personal, upstream); await wait(bank, operation);
          const stored = await engine.client.document(bank, document.id, signal);
          if (!stored || stored.original_text !== document.content || stored.retain_params?.metadata?.dahlia_ingestion_policy !== upstream) throw new HindsightError("memory_document_mismatch");
          if (!stored.memory_unit_count) throw new HindsightError("memory_no_facts");
          const hash = await contentHash(document.content);
          ledger.set(document.id, { scopeId, documentId: document.id, source: document.source, contentHash: hash,
            ingestionFingerprint: await ingestionFingerprint(hash, document.source, policy), generation: initial.generation });
        } catch (error) {
          signal.throwIfAborted();
          failures[document.id] = error instanceof HindsightError ? error.code : "memory_processing_failed";
        }
      }
      while (await engine.client.busy(bank, signal)) await poll(signal);
      const scope = store.personal ? "personal" as const : "workspace" as const;
      const aggregate = await evaluateMemory(input.questions, async (query) => {
        const result = await engine.search(identity, scopeId, query, input.reflect ?? false, signal);
        return { results: [{ scope, result: { ...result, sources: result.sources.map((source) => ({ ...source,
          id: encodeId(source.kind === "meeting" ? "meeting" : "sharedMemory", source.id) })) } }] };
      });
      signal.throwIfAborted();
      // No names of custom strategies or individual failures leave the harness.
      results.push({ variant: results.length, mode: variant.mode, strategy: variant.strategy !== null, ...aggregate });
    } finally {
      // Only the locally generated disposable bank is ever deleted, including after cancellation.
      await engine.client.deleteBank(bank, AbortSignal.timeout(30_000));
    }
  }
  return { documents: documents.length, variants: results };
}
