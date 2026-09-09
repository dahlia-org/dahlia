import type { SearchEmbedder } from "./embedding";
import {
  SearchEmbeddingError,
  SEARCH_EMBEDDING_BATCH_MAX_BYTES,
  SEARCH_EMBEDDING_BATCH_SIZE,
  SEARCH_EMBEDDING_DOCUMENT_MAX_BYTES,
} from "./embedding";
import type { SearchIndexStore, SearchIndexReference } from "./index-store";

export async function processSearchIndexBatch(
  store: SearchIndexStore,
  embedder: SearchEmbedder,
  signal?: AbortSignal,
  references?: readonly SearchIndexReference[],
): Promise<number> {
  const jobs = await store.claim(embedder.model, embedder.dimensions, SEARCH_EMBEDDING_BATCH_SIZE, references);
  const loadedDocuments = await store.loadMany(jobs);
  const encoder = new TextEncoder();
  const oversized = loadedDocuments.filter(({ embeddingText }) =>
    encoder.encode(embeddingText).byteLength > SEARCH_EMBEDDING_DOCUMENT_MAX_BYTES);
  await Promise.all(oversized.map((document) => store.fail(document, "embedding_input_too_large")));
  const documents: typeof loadedDocuments = [];
  let batchBytes = 0;
  for (const document of loadedDocuments) {
    const bytes = encoder.encode(document.embeddingText).byteLength;
    if (bytes > SEARCH_EMBEDDING_DOCUMENT_MAX_BYTES) continue;
    if (batchBytes + bytes > SEARCH_EMBEDDING_BATCH_MAX_BYTES) {
      await store.retry(document, "embedding_batch_deferred", new Date());
      continue;
    }
    batchBytes += bytes;
    documents.push(document);
  }
  const handled = new Set(loadedDocuments.map(({ vaultId, documentId }) => `${vaultId}\0${documentId}`));
  await Promise.all(jobs.filter(({ vaultId, documentId }) => !handled.has(`${vaultId}\0${documentId}`))
    .map((job) => store.discard(job)));
  if (documents.length === 0) return jobs.length;
  let vectors: number[][];
  try {
    vectors = await embedder.embedDocuments(documents.map((document) => document.embeddingText), signal);
  } catch (error) {
    const embeddingError = error instanceof SearchEmbeddingError
      ? error
      : new SearchEmbeddingError("embedding_unknown_error", true);
    await Promise.all(documents.map((document) => embeddingError.retryable
      ? store.retry(document, embeddingError.code, retryAt(document.attempts))
      : store.fail(document, embeddingError.code)));
    return jobs.length;
  }
  const saved = await store.saveMany(documents, embedder.model, embedder.dimensions, vectors);
  await Promise.all(documents.filter(({ vaultId, documentId }) => !saved.has(`${vaultId}\0${documentId}`))
    .map((document) => store.retry(document, "stale_content", new Date())));
  return jobs.length;
}

function retryAt(attempts: number): Date {
  const delayMs = Math.min(15 * 60_000, 1_000 * 2 ** Math.min(attempts, 10));
  return new Date(Date.now() + delayMs);
}
