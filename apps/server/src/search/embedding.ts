import type { AppConfig } from "../config";
import { DatabricksTokenError, DatabricksTokenProvider } from "../databricks/token";

export const SEARCH_EMBEDDING_BATCH_SIZE = 16;
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
  if (config.provider?.backend !== "databricks" || !config.databricksWorkspace) {
    throw new Error("Databricks embedding configuration is incomplete");
  }
  const tokens = new DatabricksTokenProvider(config.databricksWorkspace, transport);
  const endpoint = new URL(`${config.provider.baseUrl.replace(/\/$/, "")}/embeddings`);
  const request = async (input: string[], instruction?: string, signal?: AbortSignal): Promise<number[][]> => {
    let token: string;
    try {
      token = await tokens.getToken();
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
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
          "user-agent": "dahlia-server/0.1",
        },
        body: JSON.stringify({
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
      throw new SearchEmbeddingError(
        `embedding_http_${response.status}`,
        response.status === 429 || response.status >= 500,
      );
    }
    const body: unknown = await response.json().catch(() => undefined);
    if (!body || typeof body !== "object" || !("data" in body) || !Array.isArray(body.data)) {
      throw new SearchEmbeddingError("embedding_invalid_response", false);
    }
    const rows = body.data as unknown[];
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
      return request(input, undefined, signal);
    },
    async embedQuery(input, signal) {
      return (await request([input], QUERY_INSTRUCTION, signal))[0]!;
    },
  };
}
