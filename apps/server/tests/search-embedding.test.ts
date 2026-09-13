import { describe, expect, it, vi } from "vitest";

import type { AppConfig } from "../src/config";
import { createSearchEmbedder } from "../src/search/embedding";
import { processSearchIndexBatch } from "../src/search/node-indexer";
import { reciprocalRankFusion } from "../src/search/ranking";
import type { SearchIndexDocumentRecord, SearchIndexStore } from "../src/search/index-store";
import { MeetingSyncService } from "../src/sync/service";
import type { IdentitySyncStore, MeetingSyncStore, SyncMeetingRecord, SyncSearchQuery } from "../src/sync/types";

const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "lakebase",
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
  provider: { backend: "databricks", modelSchema: "dahlia.ai", baseUrl: "https://workspace.example/ai-gateway/mlflow/v1" },
  databricksWorkspace: {
    host: "https://workspace.example",
    clientId: "client",
    clientSecret: "secret",
    tokenUrl: "https://workspace.example/oidc/v1/token",
  },
  searchEmbedding: { model: "system.ai.embedding", dimensions: 32 },
};

describe("search embeddings", () => {
  it("uses App SP auth and validates ordered finite vectors", async () => {
    const bodies: Record<string, unknown>[] = [];
    const transport = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/oidc/v1/token")) {
        return Response.json({ access_token: "app-token", expires_in: 3600 });
      }
      expect(init?.headers).toMatchObject({ authorization: "Bearer app-token" });
      bodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      const inputCount = (bodies.at(-1)?.input as string[]).length;
      return Response.json({
        data: Array.from({ length: inputCount }, (_, index) => ({
          index: inputCount - index - 1,
          embedding: Array(32).fill(inputCount - index),
        })),
      });
    });
    const embedder = createSearchEmbedder(config, transport)!;
    expect((await embedder.embedDocuments(["first", "second"])).map((vector) => vector[0])).toEqual([1, 2]);
    await embedder.embedQuery("query");
    expect(bodies[0]).not.toHaveProperty("instruction");
    expect(bodies[1]).toMatchObject({
      model: "system.ai.embedding",
      dimensions: 32,
      input: ["query"],
    });
    expect(bodies[1]?.instruction).toContain("search query");
  });

  it("classifies transient upstream failures without exposing content", async () => {
    const transport = vi.fn(async (input: RequestInfo | URL) => String(input).endsWith("/oidc/v1/token")
      ? Response.json({ access_token: "app-token", expires_in: 3600 })
      : new Response(null, { status: 429 }));
    await expect(createSearchEmbedder(config, transport)!.embedQuery("private content"))
      .rejects.toMatchObject({
        code: "embedding_http_429",
        retryable: true,
      });
  });

  it("retries transient App SP token failures", async () => {
    const transport = vi.fn(async () => { throw new TypeError("network unavailable"); });
    await expect(createSearchEmbedder(config, transport)!.embedQuery("private content"))
      .rejects.toMatchObject({
        code: "embedding_authentication_failed",
        retryable: true,
      });
  });

  it("rejects non-finite and wrong-dimension responses", async () => {
    const responses: number[][] = [Array<number>(31).fill(1), [...Array<number>(31).fill(1), Number.NaN]];
    for (const embedding of responses) {
      const transport = vi.fn(async (input: RequestInfo | URL) => String(input).endsWith("/oidc/v1/token")
        ? Response.json({ access_token: "app-token", expires_in: 3600 })
        : Response.json({ data: [{ index: 0, embedding }] }));
      await expect(createSearchEmbedder(config, transport)!.embedQuery("query"))
        .rejects.toMatchObject({ code: "embedding_dimension_mismatch", retryable: false });
    }
  });

  it("rejects oversized document input before calling the model", async () => {
    const transport = vi.fn(async (input: RequestInfo | URL) => String(input).endsWith("/oidc/v1/token")
      ? Response.json({ access_token: "app-token", expires_in: 3600 })
      : Response.json({ data: [] }));
    expect(() => createSearchEmbedder(config, transport)!.embedDocuments(["x".repeat(64 * 1024 + 1)]))
      .toThrow("embedding_input_too_large");
    expect(transport).not.toHaveBeenCalled();
  });

  it("merges FTS and vector ranks with stable FTS preference", () => {
    expect(reciprocalRankFusion(["fts", "both"], ["vector", "both"]).map(({ documentId }) => documentId))
      .toEqual(["both", "fts", "vector"]);
  });

  it("returns the first FTS result when vector lookup fails without repeating FTS", async () => {
    const meeting: SyncMeetingRecord = {
      meetingId: "019d3f46-8b72-77f1-b232-93726eec3e9e",
      workspaceId: "019d3f46-7e0d-7d21-98d9-f1456c0bfb58",
      projectId: null,
      name: "Roadmap",
      description: "",
      status: "READY",
      duration: null,
      recordingStartedAt: null,
      createdAt: new Date(),
      updatedAt: new Date(),
      summaryTitle: null,
      summaryDocument: null,
      summaryCreatedAt: null,
    };
    const listMeetings = vi.fn(async (
      _workspaceId: string,
      query: SyncSearchQuery | undefined,
    ): Promise<SyncMeetingRecord[]> => {
      if (query?.embedding) {
        expect(query.ftsCandidateIds).toEqual([meeting.meetingId]);
        throw new Error("vector unavailable");
      }
      return [meeting];
    });
    const identityStore = {
      getWorkspace: vi.fn(() => Promise.resolve({
        workspaceId: meeting.workspaceId,
        createdAt: new Date(),
        updatedAt: new Date(),
        role: "owner",
      })),
      listMeetings,
    } as unknown as IdentitySyncStore;
    const store = {
      withIdentity: <T>(_identity: unknown, action: (scoped: IdentitySyncStore) => Promise<T>) => action(identityStore),
    } as MeetingSyncStore;
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const service = new MeetingSyncService(
      store,
      undefined,
      { tokenize: (text) => text.toLowerCase().split(/\s+/) },
      {
        model: "model",
        dimensions: 32,
        embedDocuments: vi.fn(),
        embedQuery: vi.fn(() => Promise.resolve(Array(32).fill(1))),
      },
    );
    await expect(service.listMeetings({ userId: "owner",  source: "header" },
      meeting.workspaceId, "roadmap")).resolves.toEqual({ items: [meeting] });
    expect(listMeetings).toHaveBeenCalledTimes(2);
    warn.mockRestore();
  });

  it.each(["hybrid", "offline", "revoked"])("shares one query embedding across common search kinds: %s", async (mode) => {
    const workspaceId = "019d3f46-7e0d-7d21-98d9-f1456c0bfb58";
    const meetingId = "019d3f46-8b72-77f1-b232-93726eec3e9e";
    let allowed = true;
    const meeting = { meetingId, workspaceId, projectId: null, name: "契約", description: "", createdAt: new Date(), summaryDocument: null } as SyncMeetingRecord;
    const listMeetings = vi.fn((_workspace: string, query?: SyncSearchQuery) => {
      if (query?.embedding) expect(query.ftsCandidateIds).toBeUndefined();
      return Promise.resolve([meeting]);
    });
    const listScreenshots = vi.fn((_workspace: string, _meeting: string | undefined, query?: SyncSearchQuery) => {
      if (query?.embedding) expect(query.ftsCandidateIds).toBeUndefined();
      return Promise.resolve([]);
    });
    const scoped = { getWorkspace: () => Promise.resolve(allowed ? { workspaceId } : undefined),
      listProjects: () => Promise.resolve([]), searchProjectActivity: () => Promise.resolve([]), listMeetings, listScreenshots } as unknown as IdentitySyncStore;
    const store = { withIdentity: <T>(_identity: unknown, action: (store: IdentitySyncStore) => Promise<T>) => action(scoped) } as MeetingSyncStore;
    const embedQuery = vi.fn(async () => {
      if (mode === "revoked") allowed = false;
      if (mode === "offline") throw new Error("offline");
      return Array<number>(32).fill(1);
    });
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      const service = new MeetingSyncService(store, undefined, { tokenize: (text) => [text] },
        { model: "model", dimensions: 32, embedDocuments: vi.fn(), embedQuery });
      const result = service.searchAll({ userId: "owner",  source: "header" }, { workspaceId, query: "契約" });
      if (mode === "revoked") await expect(result).rejects.toMatchObject({ status: 404 });
      else {
        expect((await result).meetings.map((hit) => hit.id)).toEqual([meetingId]);
        expect(listScreenshots).toHaveBeenCalledTimes(mode === "hybrid" ? 2 : 1);
        expect(listMeetings).toHaveBeenCalledTimes(mode === "hybrid" ? 2 : 1);
      }
      expect(embedQuery).toHaveBeenCalledTimes(1);
    } finally { warn.mockRestore(); }
  });

  it("processes a claimed batch and retries stale results", async () => {
    const document: SearchIndexDocumentRecord = {
      workspaceId: "workspace",
      documentId: "document",

      generation: 1,
      attempts: 0,
      claimedAt: new Date(),
      embeddingText: "summary",
      contentHash: "hash",
    };
    const retry = vi.fn(() => Promise.resolve());
    const store = {
      claim: vi.fn(() => Promise.resolve([document])),
      loadMany: vi.fn(() => Promise.resolve([document])),
      saveMany: vi.fn(() => Promise.resolve(new Set())),
      retry,
      discard: vi.fn(() => Promise.resolve()),
    } as unknown as SearchIndexStore;
    const embedder = {
      model: "model",
      dimensions: 32,
      embedDocuments: vi.fn(() => Promise.resolve([Array(32).fill(1)])),
    } as never;
    expect(await processSearchIndexBatch(store, embedder)).toBe(1);
    expect(retry).toHaveBeenCalledWith(document, "stale_content", expect.any(Date));
  });

  it("fails an oversized indexed document without sending it to the model", async () => {
    const document: SearchIndexDocumentRecord = {
      workspaceId: "workspace",
      documentId: "document",

      generation: 1,
      attempts: 0,
      claimedAt: new Date(),
      embeddingText: "x".repeat(64 * 1024 + 1),
      contentHash: "hash",
    };
    const fail = vi.fn(() => Promise.resolve());
    const store = {
      claim: vi.fn(() => Promise.resolve([document])),
      loadMany: vi.fn(() => Promise.resolve([document])),
      fail,
      discard: vi.fn(() => Promise.resolve()),
    } as unknown as SearchIndexStore;
    const embedDocuments = vi.fn();
    const embedder = { model: "model", dimensions: 32, embedDocuments } as never;

    expect(await processSearchIndexBatch(store, embedder)).toBe(1);
    expect(fail).toHaveBeenCalledWith(document, "embedding_input_too_large");
    expect(embedDocuments).not.toHaveBeenCalled();
  });
});
