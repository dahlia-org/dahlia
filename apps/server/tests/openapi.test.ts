import { seedHeaderIdentity, testOrganizationID, testUserID } from "./public-test-client";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import createClient from "openapi-fetch";
import { validate } from "./api-test-client";
import { createApp } from "./public-test-client";
import { contracts, openapiDocument } from "../src/api/contracts";
import { createDahliaAuth } from "../src/auth/better-auth";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { LocalObjectStorage } from "../src/storage/local";
import type { paths } from "../src/client/generated-api";
import { testStore } from "./test-store";
import { encodeId, type IDKind } from "../src/typeid";
import { fileMetadataLimits } from "../src/files/model";

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
  const meetingScope = spec.paths!["/api/v1/vaults/{vaultId}/meetings"]!.get!.parameters!
    .find((parameter) => !("$ref" in parameter) && parameter.name === "projectScope");
  expect(meetingScope).toMatchObject({ schema: { enum: ["direct", "unassigned"] } });
});

it("publishes file metadata API limits below the PostgreSQL safety limits", () => {
  const schemas = openapiDocument().components!.schemas! as Record<string, {
    properties: { ocrText: { maxLength: number }; caption: { maxLength: number } };
  }>;
  expect(schemas.FileWriteMetadata!.properties.ocrText.maxLength).toBe(fileMetadataLimits.api.ocrText);
  expect(schemas.FileWriteMetadata!.properties.caption.maxLength).toBe(fileMetadataLimits.api.caption);
  expect(schemas.FileMetadata!.properties.ocrText.maxLength).toBe(fileMetadataLimits.postgres.ocrText);
  expect(schemas.FileMetadata!.properties.caption.maxLength).toBe(fileMetadataLimits.postgres.caption);
  expect(schemas.FileWriteMetadata!.properties.ocrText.maxLength).toBeLessThanOrEqual(schemas.FileMetadata!.properties.ocrText.maxLength);
  expect(schemas.FileWriteMetadata!.properties.caption.maxLength).toBeLessThanOrEqual(schemas.FileMetadata!.properties.caption.maxLength);
});

describe("generated Web client against the real SQLite Server", () => {
  it("validates receipts, canonical reads, file staging and problem details", async () => {
    const directory = await mkdtemp(join(tmpdir(), "dahlia-openapi-"));
    const store = createNodeApplicationStore({ ...config, databaseUrl: `file:${join(directory, "server.sqlite")}` });
    try {
      await store.migrate();
      await seedHeaderIdentity(store, join(directory, "server.sqlite"), { userId: testUserID("owner"), email: "owner@example.com", source: "header", workspaceId: `personal:${testUserID("owner")}` });
      const app = createApp({ config, authStore: store, objectStorage: new LocalObjectStorage(join(directory, "objects")) });
      const client = createClient<paths>({ baseUrl: config.baseUrl, headers, fetch: async (request: Request) => {
        const response = await app.request(request);
        await validate(request, response);
        return response;
      } });
      const vaultId = id(), meetingId = id(), fileId = id();
      const transaction = { schemaVersion: 3 as const, id: id(), vaultId, createdAt: date, operations: [
        { id: id(), entity: "vault" as const, action: "create" as const, entityId: vaultId, baseRevision: null, data: { organizationId: testOrganizationID, name: "Vault", createdAt: date } },
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
      const activation = await client.POST("/api/v1/transactions", { body: { schemaVersion: 3, id: id(), vaultId, createdAt: date,
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
      const deletion = await client.POST("/api/v1/transactions", { body: { schemaVersion: 3, id: id(), vaultId, createdAt: date,
        operations: [{ id: id(), entity: "meeting", action: "delete", entityId: meetingId, baseRevision: 1, data: {} }] } });
      expect(deletion.response.status).toBe(200);
      const missing = await stage();
      expect(missing.response.status).toBe(409);
      expect(missing.error).toMatchObject({ code: "revision_conflict", conflicts: [{ entity: "meeting", id: meetingId,
        clientBaseRevision: null, serverRevision: null, record: null }] });
      const restore = await client.POST("/api/v1/transactions", { body: { schemaVersion: 3, id: id(), vaultId, createdAt: date,
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
    if (requestSchema instanceof z.ZodType && request && !("$ref" in request) && request.content["application/json"]?.example !== undefined) {
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
        if (!type.includes("json") || media.example === undefined) continue;
        const declared = source.responses[status] as { content?: Record<string, { schema: z.ZodType }> };
        const parsed = declared.content![type]!.schema.safeParse(media.example);
        expect.soft(parsed.success, `${contract.operationId} ${status}: ${JSON.stringify(parsed.error?.issues)}`).toBe(true);
      }
    }
  }
});

it("shares metadata and authentication while retaining public and browser-only overrides", () => {
  const spec = openapiDocument();
  expect(spec.security).toEqual([{ bearerAuth: [] }, { browserSession: [] }, { trustedProxy: [] }]);
  for (const contract of Object.values(contracts)) {
    const operation = spec.paths![contract.path]![contract.method as "get"]!;
    expect(operation.security).toEqual(contract.security);
  }
  expect(spec.paths!["/healthz"]!.get!.security).toEqual([]);
  expect(spec.paths!["/openapi.json"]!.get!.security).toEqual([]);
  expect(spec.paths!["/api/v1/session"]!.get!.security).toEqual([{ browserSession: [] }, { trustedProxy: [] }]);
  expect(spec.paths!["/api/v1/vaults"]!.get!.security).toBeUndefined();
  const schemas = spec.components!.schemas!;
  for (const name of ["Transcript", "NullableTranscript"]) {
    expect(schemas[name]).toMatchObject({ properties: { metadata: { $ref: "#/components/schemas/NullableTranscriptMetadata" } } });
  }
  expect(schemas.Summary).toMatchObject({ properties: { metadata: { $ref: "#/components/schemas/NullableSummaryMetadata" } } });
  expect(schemas.NullableSummaryMetadata).toMatchObject({ properties: { response: { $ref: "#/components/schemas/SummaryResponseMetadata" } } });
  expect(JSON.stringify(spec)).not.toContain("019f0d36-0520-7000-8000-000000000001");
  expect(JSON.stringify(spec)).not.toContain('"format":"uuid"');
  expect(schemas.Person).toMatchObject({ properties: { id: { pattern: "^user_[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}$" } } });

});

it("shares error responses and nullable record DTOs without losing their contracts", () => {
  const spec = openapiDocument();
  for (const contract of Object.values(contracts)) {
    const operation = spec.paths![contract.path]![contract.method as "get"]!;
    expect(Object.keys(operation.responses!)).toEqual(Object.keys(contract.responses));
    expect(Object.keys(operation.responses!).filter((status) => Number(status) >= 400)).toEqual([]);
    if (contract.responses.default) {
      expect(operation.responses!.default).toEqual({ $ref: "#/components/responses/Problem" });
      expect(spec.components!.responses!.Problem).toMatchObject({
        content: { "application/problem+json": { schema: { $ref: "#/components/schemas/Problem" } } },
      });
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

it("preserves UUIDv7 version and variant constraints in public input IDs", () => {
  const spec = openapiDocument();
  const paths: [string, IDKind][] = [
    ["components|schemas|Transaction|properties|id", "transaction"],
    ["components|schemas|Transaction|properties|operations|items|anyOf|0|properties|id", "operation"],
    ["paths|/api/v1/file-uploads|post|requestBody|content|application/json|schema|properties|id", "file"],
    [`paths|${contracts.startSummaryJob.path}|post|requestBody|content|application/json|schema|anyOf|0|properties|id`, "summaryJob"],
    [`paths|${contracts.retrySummaryJob.path}|post|requestBody|content|application/json|schema|properties|id`, "summaryJob"],
    [`paths|${contracts.transferVault.path}|post|parameters|1|schema`, "transaction"],
  ];
  for (const [path, kind] of paths) {
    let schema: unknown = spec;
    for (const key of path.split("|")) schema = (schema as Record<string, unknown>)[key];
    const pattern = new RegExp(z.object({ pattern: z.string() }).parse(schema).pattern);
    for (const version of [0, 4, 7, 8]) for (const variant of [0, 8, 9, 10, 11, 12, 15]) {
      const uuid = `ffffffff-ffff-${version}fff-${variant.toString(16)}fff-ffffffffffff`;
      expect(pattern.test(encodeId(kind, uuid)), `${path}: ${uuid}`).toBe(version === 7 && variant >= 8 && variant <= 11);
    }
  }
});
