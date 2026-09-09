import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import createClient from "openapi-fetch";
import { validate } from "./api-test-client";
import { createApp } from "../src/app";
import { contracts, openapiDocument } from "../src/api/contracts";
import { createDahliaAuth } from "../src/auth/better-auth";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { LocalObjectStorage } from "../src/storage/local";
import type { paths } from "../src/client/generated-api";
import { testStore } from "./test-store";

const config = { authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "sqlite" as const,
  baseUrl: "http://localhost:5173", storageBackend: "databricks" as const, storageDatabricksVolumePath: "/Volumes/test/app/files", oauthRedirectUris: [], maxRequestBytes: 8 * 1024 * 1024 };
const headers = { "x-forwarded-email": "owner@example.com", "x-forwarded-user": "owner", "x-dahlia-vault-transfers": "1" };
const id = () => crypto.randomUUID().replace(/^(.{14})./, "$17");
const date = "2026-09-09T00:00:00.000Z";
type PublishedResponse = { $ref?: string; headers?: unknown; content?: Record<string, { schema?: unknown; example?: unknown }> };


it("covers every Dahlia route exactly once and publishes the generated contract", async () => {
  const app = createApp({ config, authStore: testStore() });
  const spec = openapiDocument();
  const ids = Object.values(contracts).map((route) => route.operationId);
  expect(new Set(ids).size).toBe(ids.length);
  for (const contract of Object.values(contracts)) {
    expect(app.routes.some((route) => route.method === contract.method.toUpperCase()
      && route.path === contract.path.replace(/\{([^}]+)\}/g, ":$1")), contract.operationId).toBe(true);
    expect(spec.paths?.[contract.path]).toHaveProperty(`${contract.method}.operationId`, contract.operationId);
  }
  const owned = new Set(Object.values(contracts).map((route) => `${route.method.toUpperCase()} ${route.path.replace(/\{([^}]+)\}/g, ":$1")}`));
  for (const route of app.routes.filter((route) => route.method !== "ALL" && route.path.startsWith("/api/v1/")
    && !["/api/v1/models", "/api/v1/responses"].includes(route.path))) {
    expect(owned.has(`${route.method} ${route.path}`), `${route.method} ${route.path}`).toBe(true);
  }
  expect(await (await app.request("/openapi.json")).json()).toEqual(spec);
});

describe("generated Web client against the real SQLite Server", () => {
  it("validates receipts, canonical reads, file staging and problem details", async () => {
    const directory = await mkdtemp(join(tmpdir(), "dahlia-openapi-"));
    const store = createNodeApplicationStore({ ...config, databaseUrl: `file:${join(directory, "server.sqlite")}` });
    try {
      await store.migrate();
      const app = createApp({ config, authStore: store, objectStorage: new LocalObjectStorage(join(directory, "objects")) });
      const client = createClient<paths>({ baseUrl: config.baseUrl, headers, fetch: async (request: Request) => {
        const response = await app.request(request);
        await validate(request, response);
        return response;
      } });
      const vaultId = id(), meetingId = id(), fileId = id();
      const transaction = { schemaVersion: 2 as const, id: id(), vaultId, createdAt: date, operations: [
        { id: id(), entity: "vault" as const, action: "create" as const, entityId: vaultId, baseRevision: null, data: { name: "Vault", createdAt: date } },
        { id: id(), entity: "meeting" as const, action: "create" as const, entityId: meetingId, baseRevision: null,
          data: { name: "Meeting", description: "", status: "READY" as const, projectId: null, duration: null, recordingStartedAt: null, createdAt: date, updatedAt: date } },
      ] };
      const committed = await client.POST("/api/v1/transactions", { body: transaction });
      expect(committed.response.status, JSON.stringify(committed.error)).toBe(200);
      expect((await client.POST("/api/v1/transactions", { body: transaction })).data).toEqual(committed.data);
      expect((await client.POST("/api/v1/transactions/resolve", { body: transaction })).data).toEqual(committed.data);
      expect((await client.POST("/api/v1/transactions", { body: { ...transaction, createdAt: "2026-09-10T00:00:00Z" } })).response.status).toBe(409);
      await client.GET("/api/v1/session");
      await client.GET("/api/v1/capabilities");
      await client.GET("/api/v1/account/settings");
      await client.PATCH("/api/v1/account/settings", { body: { outputLanguage: "ja" } });
      await client.GET("/api/v1/vaults");
      await client.GET("/api/v1/organizations");
      await client.GET("/api/v1/vaults/{vaultId}", { params: { path: { vaultId } } });
      await client.GET("/api/v1/vaults/{vaultId}/projects", { params: { path: { vaultId } } });
      await client.GET("/api/v1/vaults/{vaultId}/meetings", { params: { path: { vaultId } } });
      await client.GET("/api/v1/vaults/{vaultId}/snapshot", { params: { path: { vaultId } } });
      await client.GET("/api/v1/vaults/{vaultId}/changes", { params: { path: { vaultId } } });
      await client.GET("/api/v1/meetings/{meetingId}", { params: { path: { meetingId } } });
      await client.GET("/api/v1/meetings/{meetingId}/summaries/latest", { params: { path: { meetingId } } });
      await client.GET("/api/v1/meetings/{meetingId}/transcripts/latest", { params: { path: { meetingId } } });
      await client.GET("/api/v1/meetings/{meetingId}/summaries", { params: { path: { meetingId } } });
      await client.GET("/api/v1/meetings/{meetingId}/transcripts", { params: { path: { meetingId } } });
      await client.GET("/api/v1/meetings/{meetingId}/recordings", { params: { path: { meetingId } } });
      const reservationBody = { id: fileId.toUpperCase(), vaultId: vaultId.toUpperCase(), name: "sample.txt", contentType: "text/plain", metadata: { source: "upload" as const } };
      const reservation = await client.POST("/api/v1/file-uploads", { body: reservationBody });
      expect(reservation.response.status).toBe(201);
      expect(reservation.response.headers.get("location")).toBe(`/api/v1/file-uploads/${fileId}/content`);
      const replay = await client.POST("/api/v1/file-uploads", { body: { ...reservationBody, id: fileId, vaultId } });
      expect(replay.data).toEqual(reservation.data);
      const upload = await client.PUT("/api/v1/file-uploads/{fileId}/content", { params: { path: { fileId }, header: { "content-type": "application/octet-stream", "content-length": "5" } },
        body: "hello", bodySerializer: (body) => body });
      expect(upload.response.status).toBe(201);
      const activation = await client.POST("/api/v1/transactions", { body: { schemaVersion: 2, id: id(), vaultId, createdAt: date,
        operations: [{ id: id(), entity: "file", action: "upsert", entityId: fileId, baseRevision: null, data: { checksum: upload.data!.checksum, metadata: {} } }] } });
      expect(activation.response.status, JSON.stringify(activation.error)).toBe(200);
      await client.GET("/api/v1/files/{fileId}", { params: { path: { fileId } } });
      await client.GET("/api/v1/vaults/{vaultId}/files", { params: { path: { vaultId } } });
      const chunk = { segments: [], deletions: [] };
      const chunkHash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(chunk))))]
        .map((byte) => byte.toString(16).padStart(2, "0")).join("");
      const chunkParams = { path: { meetingId, patchId: id(), chunkIndex: "0" }, header: { "x-dahlia-content-sha256": chunkHash } };
      const stage = () => client.PUT("/api/v1/meetings/{meetingId}/transcript-uploads/{patchId}/chunks/{chunkIndex}", { params: chunkParams, body: chunk });
      expect((await stage()).response.status).toBe(204);
      expect((await stage()).response.status).toBe(204);
      const deletion = await client.POST("/api/v1/transactions", { body: { schemaVersion: 2, id: id(), vaultId, createdAt: date,
        operations: [{ id: id(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }] } });
      expect(deletion.response.status).toBe(200);
      const missing = await stage();
      expect(missing.response.status).toBe(409);
      expect(missing.error).toMatchObject({ code: "revision_conflict", conflicts: [{ entity: "meeting", id: meetingId,
        clientBaseRevision: null, serverRevision: null, record: null }] });
      const restore = await client.POST("/api/v1/transactions", { body: { schemaVersion: 2, id: id(), vaultId, createdAt: date,
        operations: [{ ...transaction.operations[1]!, id: id() }] } });
      expect(restore.response.status).toBe(200);
      expect((await stage()).response.status).toBe(204);
      const foreign = await client.PUT("/api/v1/meetings/{meetingId}/transcript-uploads/{patchId}/chunks/{chunkIndex}", {
        params: chunkParams, body: chunk, headers: { "x-forwarded-user": "other", "x-forwarded-email": "other@example.com" },
      });
      expect(foreign.response.status).toBe(409);
      expect(foreign.error).toMatchObject({ conflicts: [{ record: null, serverRevision: null }] });
      const invalid = new Request(`${config.baseUrl}/api/v1/vaults?organizationId=a&organizationId=b`, { headers });
      const rejected = await app.request(invalid);
      await validate(invalid, rejected);
      expect(rejected.status).toBe(400);
    } finally { await store.close?.(); await rm(directory, { recursive: true, force: true }); }
  });
});

it("keeps every published JSON example valid against the source wire schema", () => {
  const spec = openapiDocument();
  for (const contract of Object.values(contracts)) {
    const operation = spec.paths?.[contract.path]?.[contract.method as "get"];
    const request = operation?.requestBody;
    const source = contracts[contract.operationId as keyof typeof contracts] as import("@hono/zod-openapi").RouteConfig;
    const requestMedia = source.request?.body?.content?.["application/json"];
    const requestSchema = requestMedia && !("$ref" in requestMedia) ? requestMedia.schema : undefined;
    if (requestSchema instanceof z.ZodType && request && !("$ref" in request)) {
      const parsed = requestSchema.safeParse(request.content["application/json"]?.example);
      expect.soft(parsed.success, `${contract.operationId} request: ${JSON.stringify(parsed.error?.issues)}`).toBe(true);
    }
    const responses: Record<string, PublishedResponse> = operation?.responses ?? {};
    for (const [status, declaredResponse] of Object.entries(responses)) {
      const response: PublishedResponse = declaredResponse.$ref
        ? spec.components!.responses![declaredResponse.$ref.split("/").at(-1)!]!
        : declaredResponse;
      expect(response).toBeDefined();
      if ("$ref" in response) throw new Error("Expected a concrete shared response");
      for (const [type, media] of Object.entries(response.content ?? {})) {
        if (!type.includes("json")) continue;
        const declared = source.responses[status] as { content?: Record<string, { schema: z.ZodType }> };
        const parsed = declared.content![type]!.schema.safeParse(media.example);
        expect.soft(parsed.success, `${contract.operationId} ${status}: ${JSON.stringify(parsed.error?.issues)}`).toBe(true);
      }
    }
  }
});

it("shares error responses and nullable record DTOs without losing their contracts", () => {
  const spec = openapiDocument();
  const responses = spec.components!.responses! as Record<string, PublishedResponse>;
  expect(Object.keys(responses)).toHaveLength(18);
  for (const contract of Object.values(contracts)) {
    const operation = spec.paths![contract.path]![contract.method as "get"]!;
    for (const [status, response] of Object.entries(operation.responses!)) {
      if (Number(status) < 400) continue;
      expect(response).toEqual({ $ref: `#/components/responses/Problem${status}` });
      const shared = responses[`Problem${status}`]!;
      if ("$ref" in shared) throw new Error("Expected a concrete shared response");
      const source = contract.responses[status]!;
      if ("$ref" in source) throw new Error("Expected a source response definition");
      expect(shared.headers).toEqual(source.headers);
      expect(shared.content!["application/problem+json"]!.schema).toEqual({ $ref: "#/components/schemas/Problem" });
      expect(shared.content!["application/problem+json"]!.example).toMatchObject({ status: Number(status) });
    }
  }
  // Nullable components preserve tombstones without unsupported Swift unions or allOf that rejects null.
  const schemas = spec.components!.schemas! as Record<string, {
    type?: string[];
    anyOf?: { properties: Record<string, unknown>; required: string[] }[];
    properties: Record<string, { items: { anyOf: { properties: Record<string, unknown>; required: string[] }[] } }>;
  }>;
  for (const name of ["CanonicalRecord", "RevisionConflict", "Changes"]) {
    const variants = name === "Changes" ? schemas[name]!.properties.items!.items.anyOf : schemas[name]!.anyOf!;
    const vault = variants.find((variant) => (variant.properties.entity as { enum: string[] }).enum[0] === "vault")!;
    expect(vault.properties.record).toEqual({ $ref: "#/components/schemas/NullableVaultRecord" });
    expect(schemas.NullableVaultRecord!.type).toEqual(["object", "null"]);
    expect(vault.required.includes("record")).toBe(name !== "CanonicalRecord");
  }
  for (const name of ["NullableTranscriptRecord", "TranscriptContent"]) {
    expect(schemas[name]!.properties.transcript).toEqual({ $ref: "#/components/schemas/NullableTranscript" });
  }
  expect(schemas.NullableTranscript!.type).toEqual(["object", "null"]);
});

it("audits the concrete installed Better Auth endpoints and MCP tools", async () => {
  const directory = await mkdtemp(join(tmpdir(), "dahlia-protocol-audit-"));
  const authConfig = { ...config, authProvider: "accounts" as const, databaseUrl: `file:${join(directory, "server.sqlite")}`,
    betterAuthSecret: "test-only-placeholder-secret-32-characters", googleClientId: "test", googleClientSecret: "test" };
  const store = createNodeApplicationStore(authConfig);
  try {
    await store.migrate();
    const auth = createDahliaAuth(authConfig, store);
    await auth.$context;
    const audit = z.object({ delegated: z.array(z.object({ operation: z.string(), method: z.string(), path: z.string() })),
      mcp: z.object({ tools: z.array(z.string()) }) }).parse(JSON.parse(await readFile(new URL("../api-audit.json", import.meta.url), "utf8")));
    const actual = Object.entries(auth.api).filter(([, endpoint]) => endpoint.path).flatMap(([name, endpoint]) => {
      const methods = Array.isArray(endpoint.options.method) ? endpoint.options.method : [endpoint.options.method];
      return methods.map((method) => `${name} ${method} /api/auth${endpoint.path}`);
    }).sort();
    expect(actual).toEqual(audit.delegated.filter((entry) => entry.path.startsWith("/api/auth/")).map((entry) => `${entry.operation} ${entry.method} ${entry.path}`).sort());
    const mcpSource = await readFile(new URL("../src/mcp.ts", import.meta.url), "utf8");
    expect([...mcpSource.matchAll(/server.registerTool\("([^"]+)"/g)].map((match) => match[1]).sort()).toEqual(audit.mcp.tools.toSorted());
  } finally { await store.close?.(); await rm(directory, { recursive: true, force: true }); }
});
