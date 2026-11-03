import type { SessionSearchStore } from "../agent/session-search";
import type { BackgroundJob, JobStore } from "../jobs/store";
import { isRateLimited, RATE_LIMIT_COOLDOWN_MS } from "../jobs/rate-limit";
import { embedChunks } from "../search/chunk-embedding";
import { SearchEmbeddingError, type SearchEmbedder } from "../search/embedding";
import type { SearchAnalyzer } from "../search/lexical";
import type { MemoryStore } from "./store";

export interface MemoryIndexServices {
  queue: JobStore;
  analyzer: SearchAnalyzer;
  memory?: { personal: MemoryStore; workspace: MemoryStore };
  sessions?: SessionSearchStore;
  embedder?: SearchEmbedder;
}
const SESSION_EMBEDDING_PAGE = 64;

/** One memory-index job: embed a memory's chunks, or (re)build a saved chat's chunks and embed them. */
export async function processMemoryIndexJob(services: MemoryIndexServices, job: BackgroundJob, signal: AbortSignal): Promise<void> {
  const payload = job.payload;
  const { embedder } = services;
  const config = embedder ? { model: embedder.model, dimensions: embedder.dimensions } : undefined;
  if (payload.source === "session") {
    const sessions = services.sessions;
    if (!sessions) return;
    let after: string | undefined;
    do after = await sessions.index(payload.ownerUserId!, payload.threadId!, services.analyzer, after); while (after && !signal.aborted);
    signal.throwIfAborted();
    if (!config) return;
    const pending = await sessions.pendingEmbeddings(payload.ownerUserId!, payload.threadId!, config, SESSION_EMBEDDING_PAGE);
    if (await embed(services, job, pending, (rows) => sessions.saveEmbeddings(payload.ownerUserId!, config.model, rows), signal)
      && pending.length === SESSION_EMBEDDING_PAGE) await services.queue.reschedule(job, payload, 0);
    return;
  }
  // A job queued for another model is superseded; reconciliation queues the current one.
  if (!config || !services.memory || payload.model !== config.model || payload.dimensions !== config.dimensions) return;
  const store = payload.source === "personal" ? services.memory.personal : services.memory.workspace;
  const pending = await store.pendingEmbeddings(payload.scopeId!, payload.documentId!, config);
  await embed(services, job, pending, (rows) => store.saveEmbeddings(payload.scopeId!, payload.documentId!, config.model, rows), signal);
}

// Returns whether every chunk was embedded. Lexical search keeps working meanwhile: retryable failures back off,
// rejected input stays failed until the content changes.
async function embed<T extends { text: string }>(services: MemoryIndexServices, job: BackgroundJob, pending: T[],
  save: (rows: Array<T & { vector: number[] }>) => Promise<void>, signal: AbortSignal): Promise<boolean> {
  if (!pending.length) return true;
  let vectors: Array<number[] | undefined>;
  try {
    vectors = await embedChunks(services.embedder!, pending.map((chunk) => chunk.text), signal);
  } catch (error) {
    if (!(error instanceof SearchEmbeddingError)) throw error;
    if (!error.retryable) await services.queue.fail(job, error.code);
    else {
      if (isRateLimited(error.code)) await services.queue.cooldown("memory-index", Date.now() + RATE_LIMIT_COOLDOWN_MS);
      await services.queue.retry(job, { delayMs: Math.min(15 * 60_000, 1_000 * 2 ** Math.min(job.attempts, 10)), errorCode: error.code });
    }
    return false;
  }
  await save(pending.flatMap((chunk, index) => vectors[index] ? [{ ...chunk, vector: vectors[index] }] : []));
  if (vectors.every(Boolean)) return true;
  await services.queue.fail(job, "embedding_input_rejected");
  return false;
}
