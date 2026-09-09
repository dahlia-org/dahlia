import type { AppConfig } from "../config";
import { createJobProvider } from "../ai-gateway/job-provider";
import { DatabricksTokenError } from "../databricks/token";

export const SEARCH_EMBEDDING_BATCH_SIZE = 16;
export const SEARCH_EMBEDDING_DOCUMENT_MAX_BYTES = 64 * 1024;
export const SEARCH_EMBEDDING_BATCH_MAX_BYTES = 512 * 1024;
const SEARCH_EMBEDDING_TIMEOUT_MS = 30_000;
const QUERY_INSTRUCTION = "Given a search query, retrieve relevant Dahlia meeting content.";

export interface SearchEmbedder {
  readonly model: string;
  readonly dimensions: number;
  embedDocuments(input: string[], signal?: AbortSignal): Promise<number[][]>;
  embedQuery(input: string, signal?: AbortSignal): Promise<number[]>;
}

export class SearchEmbeddingError extends Error {
  constructor(readonly code: string, readonly retryable: boolean) {
    super(code);
  }
}

export function createSearchEmbedder(
  config: AppConfig,
  transport: typeof fetch = fetch,
): SearchEmbedder | undefined {
  const embedding = config.searchEmbedding;
  if (!embedding) return undefined;
  const execution = createJobProvider(config, transport);
  if (!execution) throw new Error("Embedding provider is not configured");
  const cloudflare = execution.provider.backend === "cloudflare";
  const endpoint = new URL(cloudflare
    ? `${execution.provider.baseUrl.replace(/\/v1\/?$/, "")}/run/${embedding.model}`
    : `${execution.provider.baseUrl.replace(/\/$/, "")}/embeddings`);
  const request = async (input: string[], instruction?: string, signal?: AbortSignal): Promise<number[][]> => {
    let headers: Record<string, string>;
    try {
      headers = await execution.headers();
    } catch (error) {
      throw new SearchEmbeddingError(
        "embedding_authentication_failed",
        error instanceof DatabricksTokenError && error.retryable,
      );
    }
    let response: Response;
    try {
      response = await transport(endpoint, {
        method: "POST",
        headers: {
          accept: "application/json",
          ...headers,
          "content-type": "application/json",
          "user-agent": "dahlia-server/0.1",
        },
        body: JSON.stringify(cloudflare ? { text: input } : {
          model: embedding.model,
          input,
          dimensions: embedding.dimensions,
          ...(instruction ? { instruction } : {}),
        }),
        signal: signal
          ? AbortSignal.any([signal, AbortSignal.timeout(SEARCH_EMBEDDING_TIMEOUT_MS)])
          : AbortSignal.timeout(SEARCH_EMBEDDING_TIMEOUT_MS),
      });
    } catch {
      throw new SearchEmbeddingError("embedding_transport_failed", true);
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new SearchEmbeddingError(
        `embedding_http_${response.status}`,
        response.status === 429 || response.status >= 500,
      );
    }
    let responseBytes = 0;
    const bounded = response.body?.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        responseBytes += chunk.byteLength;
        if (responseBytes > 4 * 1024 * 1024) throw new SearchEmbeddingError("embedding_response_too_large", false);
        controller.enqueue(chunk);
      },
    }));
    let raw: unknown;
    try { raw = await new Response(bounded).json(); }
    catch (error) {
      if (error instanceof SearchEmbeddingError) throw error;
      throw new SearchEmbeddingError(error instanceof SyntaxError ? "embedding_invalid_response" : "embedding_transport_failed", !(error instanceof SyntaxError));
    }
    if (cloudflare && raw && typeof raw === "object" && "success" in raw && raw.success !== true) {
      throw new SearchEmbeddingError("embedding_invalid_response", false);
    }
    const result = cloudflare && raw && typeof raw === "object" && "result" in raw ? raw.result : raw;
    if (!result || typeof result !== "object" || !("data" in result) || !Array.isArray(result.data)) {
      throw new SearchEmbeddingError("embedding_invalid_response", false);
    }
    const rows: unknown[] = cloudflare
      ? result.data.map((vector: unknown, index: number) => ({ index, embedding: vector }))
      : result.data;
    if (rows.length !== input.length) throw new SearchEmbeddingError("embedding_count_mismatch", false);
    const vectors = new Array<number[]>(input.length);
    for (const row of rows) {
      if (!row || typeof row !== "object" || !("index" in row) || !Number.isInteger(row.index)
        || !("embedding" in row) || !Array.isArray(row.embedding)) {
        throw new SearchEmbeddingError("embedding_invalid_response", false);
      }
      const index = row.index as number;
      const vector = row.embedding;
      const invalidIndex = index < 0 || index >= input.length || vectors[index] !== undefined;
      const invalidVector = vector.length !== embedding.dimensions
        || vector.some((value) => typeof value !== "number" || !Number.isFinite(value));
      if (invalidIndex || invalidVector) {
        throw new SearchEmbeddingError("embedding_dimension_mismatch", false);
      }
      vectors[index] = vector as number[];
    }
    return vectors;
  };
  return {
    ...embedding,
    embedDocuments(input, signal) {
      if (input.length === 0 || input.length > SEARCH_EMBEDDING_BATCH_SIZE) {
        throw new SearchEmbeddingError("embedding_invalid_batch", false);
      }
      const byteLengths = input.map((value) => new TextEncoder().encode(value).byteLength);
      if (byteLengths.some((length) => length > SEARCH_EMBEDDING_DOCUMENT_MAX_BYTES)
        || byteLengths.reduce((sum, length) => sum + length, 0) > SEARCH_EMBEDDING_BATCH_MAX_BYTES) {
        throw new SearchEmbeddingError("embedding_input_too_large", false);
      }
      return request(input, undefined, signal);
    },
    async embedQuery(input, signal) {
      return (await request([input], QUERY_INSTRUCTION, signal))[0]!;
    },
  };
}
