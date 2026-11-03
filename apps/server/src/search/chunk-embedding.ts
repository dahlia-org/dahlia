import { chunkText } from "./chunk";
import {
  SearchEmbeddingError, SEARCH_EMBEDDING_BATCH_MAX_BYTES, SEARCH_EMBEDDING_BATCH_SIZE, type SearchEmbedder,
} from "./embedding";

// Statuses that reject the input itself; a smaller input may pass.
const INPUT_REJECTED = new Set(["embedding_http_400", "embedding_http_413", "embedding_http_422", "embedding_input_too_large"]);
const MIN_SPLIT_BYTES = 2_000;
const MAX_SPLIT_DEPTH = 2;
const encoder = new TextEncoder();

/**
 * Embeds chunk texts in bounded batches. A rejected batch is retried one text at a time; a rejected text is split in
 * halves (at most twice, never below 2,000 bytes) and represented by the normalized mean of its parts.
 * Returns undefined for a text that is still rejected. Throws retryable SearchEmbeddingErrors, and the rejection itself
 * when a minimal input is rejected too: then the request or configuration is at fault, not the text.
 * onResult receives each text's result before the next request, so a caller can persist progress an abort would lose.
 */
export async function embedChunks(embedder: SearchEmbedder, texts: readonly string[], signal?: AbortSignal,
  onResult: (index: number, vector: number[] | undefined) => Promise<void> = async () => {}): Promise<Array<number[] | undefined>> {
  const result = new Array<number[] | undefined>(texts.length);
  let probe: Promise<void> | undefined;
  // Checked once, at the first rejection.
  const textAtFault = (error: unknown) => {
    if (!rejected(error)) throw error;
    return probe ??= embedder.embedDocuments(["."], signal).then(() => undefined);
  };
  let batch: number[] = [], bytes = 0;
  const flush = async () => {
    if (!batch.length) return;
    const indexes = batch;
    batch = []; bytes = 0;
    try {
      const vectors = await embedder.embedDocuments(indexes.map((index) => texts[index]!), signal);
      for (const [position, index] of indexes.entries()) { result[index] = vectors[position]; await onResult(index, result[index]); }
    } catch (error) {
      await textAtFault(error);
      for (const index of indexes) {
        result[index] = await single(embedder, texts[index]!, 0, textAtFault, signal);
        await onResult(index, result[index]);
      }
    }
  };
  for (const [index, text] of texts.entries()) {
    const size = encoder.encode(text).byteLength;
    if (batch.length === SEARCH_EMBEDDING_BATCH_SIZE || bytes + size > SEARCH_EMBEDDING_BATCH_MAX_BYTES) await flush();
    batch.push(index); bytes += size;
  }
  await flush();
  return result;
}

function rejected(error: unknown): boolean {
  return error instanceof SearchEmbeddingError && !error.retryable && INPUT_REJECTED.has(error.code);
}

async function single(embedder: SearchEmbedder, text: string, depth: number, textAtFault: (error: unknown) => Promise<void>,
  signal?: AbortSignal): Promise<number[] | undefined> {
  try {
    return (await embedder.embedDocuments([text], signal))[0];
  } catch (error) {
    await textAtFault(error);
    const half = Math.ceil(encoder.encode(text).byteLength / 2);
    if (depth >= MAX_SPLIT_DEPTH || half < MIN_SPLIT_BYTES) return undefined;
    const parts: number[][] = [];
    for (const part of chunkText(text, half)) {
      const vector = await single(embedder, part, depth + 1, textAtFault, signal);
      if (!vector) return undefined;
      parts.push(vector);
    }
    const mean = parts[0]!.map((_, dimension) => parts.reduce((sum, vector) => sum + vector[dimension]!, 0) / parts.length);
    const norm = Math.hypot(...mean);
    return norm ? mean.map((value) => value / norm) : undefined;
  }
}
