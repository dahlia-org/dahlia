import { describe, expect, it, vi } from "vitest";
import { chunkText, SEARCH_CHUNK_MAX_BYTES } from "../src/search/chunk";
import { embedChunks } from "../src/search/chunk-embedding";
import { SearchEmbeddingError, type SearchEmbedder } from "../src/search/embedding";
import { fts5Query, lexemeQuery } from "../src/search/lexical";

const bytes = (text: string) => new TextEncoder().encode(text).byteLength;

describe("search chunks", () => {
  it("splits at paragraph, line and sentence boundaries within the byte budget without overlap", () => {
    const paragraph = "あ".repeat(1_000);
    const text = `${paragraph}\n\n${paragraph}\n${"文。".repeat(2_000)}${"😀".repeat(3_000)}`;
    const chunks = chunkText(text);
    expect(chunks.join("")).toBe(text);
    expect(chunks.every((chunk) => bytes(chunk) <= SEARCH_CHUNK_MAX_BYTES)).toBe(true);
    // 2 x 3,000 bytes fit before the paragraph break; the next chunk ends after a sentence.
    expect(chunks[0]!.endsWith("\n")).toBe(true);
    expect(chunks.slice(1, -2).every((chunk) => chunk.endsWith("。") || chunk.endsWith("\n"))).toBe(true);
    // Surrogate pairs are never split.
    expect(chunks.every((chunk) => !/[\uD800-\uDBFF]$/u.test(chunk))).toBe(true);
    expect(chunkText("短い")).toEqual(["短い"]);
    expect(chunkText("")).toEqual([]);
  });

  it("quotes lexemes and tokens so query syntax never applies", () => {
    expect(lexemeQuery(["it's", "a\\b", "予算"], false)).toBe("'it''s' | 'a\\\\b' | '予算'");
    expect(lexemeQuery(["a", "b"], true)).toBe("'a' & 'b'");
    expect(fts5Query(['say "hi"', "NEAR"], false)).toBe('"say ""hi""" OR "NEAR"');
  });

  it("retries a rejected batch one text at a time and splits a rejected text into averaged halves", async () => {
    const calls: string[][] = [];
    const embedder: SearchEmbedder = { model: "m", dimensions: 2, embedQuery: vi.fn(),
      async embedDocuments(input) {
        calls.push([...input]);
        if (input.length > 1 || bytes(input[0]!) > 5_000) throw new SearchEmbeddingError("embedding_http_413", false);
        return input.map((text) => text.startsWith("a") ? [1, 0] : [0, 1]);
      } };
    const long = `${"a".repeat(4_000)}${"b".repeat(4_000)}`;
    const vectors = await embedChunks(embedder, ["a short", long]);
    expect(vectors[0]).toEqual([1, 0]);
    expect(vectors[1]![0]).toBeCloseTo(Math.SQRT1_2);
    expect(vectors[1]![1]).toBeCloseTo(Math.SQRT1_2);
    expect(calls.map((call) => call.length)).toEqual([2, 1, 1, 1, 1]);
    // Below the minimum split size the text stays without a vector (lexical only).
    const rejecting: SearchEmbedder = { ...embedder, async embedDocuments() { throw new SearchEmbeddingError("embedding_http_400", false); } };
    expect(await embedChunks(rejecting, ["x".repeat(3_000)])).toEqual([undefined]);
    // Rate limits and timeouts are retried by the job, never split.
    const limited: SearchEmbedder = { ...embedder, async embedDocuments() { throw new SearchEmbeddingError("embedding_http_429", true); } };
    await expect(embedChunks(limited, ["x"])).rejects.toMatchObject({ code: "embedding_http_429" });
    const timeout: SearchEmbedder = { ...embedder, async embedDocuments() { throw new SearchEmbeddingError("embedding_transport_failed", true); } };
    await expect(embedChunks(timeout, ["x"])).rejects.toMatchObject({ retryable: true });
  });

  it("keeps batches within the provider limits", async () => {
    const sizes: number[] = [];
    const embedder: SearchEmbedder = { model: "m", dimensions: 2, embedQuery: vi.fn(),
      async embedDocuments(input) { sizes.push(input.length); return input.map(() => [1, 0]); } };
    expect(await embedChunks(embedder, Array.from({ length: 40 }, () => "x"))).toHaveLength(40);
    expect(sizes).toEqual([16, 16, 8]);
  });
});
