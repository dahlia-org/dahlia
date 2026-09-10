import { publicRoute } from "../src/public-wire";
import { testStore } from "./test-store";
import { createHash, createHmac } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type SQLInputValue, DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { z } from "zod";
import { createApp } from "../src/app";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { createD1ApplicationStore, type D1PreparedStatementLike } from "../src/auth/store";
import { LocalObjectStorage } from "../src/storage/local";
import { uuidV7 } from "../src/id";
import { decodeId, encodeId } from "../src/typeid";
import { createWorkerHandler } from "../src/worker";

it("covers every registered resource route and method at the public boundary", () => {
  const app = createApp({ config: { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite",
    baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024 }, authStore: testStore() });
  // OAuth refresh-token record IDs are outside the public entity ID contract.
  const excluded = new Set(["/api/v1/sessions/:id"]);
  const resources = app.routes.filter((route) => route.method !== "ALL" && route.path.includes(":") && !excluded.has(route.path));
  expect(resources.length).toBeGreaterThan(0);
  const missing = resources.filter((route) => !publicRoute(route.path.replace(/:[^/]+/g, "id"), route.method))
    .map((route) => `${route.method} ${route.path}`);
  expect(missing).toEqual([]);
});

it.each(["node", "worker"])("keeps public TypeIDs and persisted UUIDs separate through %s", async (runtime) => {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-public-ids-"));
  const path = join(directory, "empty.sqlite");
  const config = { authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "sqlite" as const,
    storageBackend: "databricks" as const, storageDatabricksVolumePath: "/Volumes/test/files",
    databaseUrl: `file:${path}`, baseUrl: "https://public.example", oauthRedirectUris: [], maxRequestBytes: 1048576 };
  const store = createNodeApplicationStore(config);
  await store.migrate();
  const database = new DatabaseSync(path);
  const app = createApp({ config, authStore: store, objectStorage: new LocalObjectStorage(join(directory, "files")) });
  const worker = createWorkerHandler(async () => app);
  const workerFetch = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
  const headers = { "x-forwarded-user": "external-subject", "x-forwarded-email": "owner@example.com", "content-type": "application/json" };
  const send = (path: string, init: RequestInit = {}) => {
    const request = new Request(`${config.baseUrl}${path}`, { ...init, headers: { ...headers, ...init.headers } });
    return runtime === "node" ? app.request(request) : workerFetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
  };
  const vault = uuidV7(), meeting = uuidV7(), attachment = uuidV7(), file = uuidV7(), transcript = uuidV7(), segment = uuidV7(), patch = uuidV7();
  const vlt = encodeId("vault", vault), mtg = encodeId("meeting", meeting), att = encodeId("attachment", attachment), fileID = encodeId("file", file);
  const now = new Date().toISOString();
  const transaction = (operations: unknown[]) => ({ schemaVersion: 2, id: encodeId("transaction", uuidV7()), vaultId: vlt, createdAt: now, operations });
  const operation = (entity: string, action: string, entityId: string, baseRevision: number | null, data: unknown) => ({
    id: encodeId("operation", entity === "transcript" ? patch : uuidV7()), entity, action, entityId, baseRevision, data,
  });
  const post = (body: unknown) => send("/api/v1/transactions", { method: "POST", body: JSON.stringify(body) });
  try {
    const spec = z.object({
      components: z.object({ schemas: z.record(z.string(), z.looseObject({})) }),
      paths: z.record(z.string(), z.looseObject({})),
    }).parse(await (await send("/openapi.json")).json());
    // Zod's JSON Schema reader resolves local $defs; the published component schemas stay otherwise unchanged.
    const definitions = z.record(z.string(), z.looseObject({})).parse(
      JSON.parse(JSON.stringify(spec.components.schemas).replaceAll("#/components/schemas/", "#/$defs/")),
    );
    const publicSchema = (name: string) => z.fromJSONSchema({ $ref: `#/$defs/${name}`, $defs: definitions });
    const pathParameter = z.object({ parameters: z.array(z.looseObject({})) })
      .parse(spec.paths["/api/v1/vaults/{vaultId}"]!.get).parameters[0];
    expect(pathParameter).toMatchObject({ name: "vaultId", schema: { pattern: "^vlt_[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}$" } });
    const sessions = await Promise.all(Array.from({ length: 12 }, async () => {
      const response = await send("/api/v1/session");
      expect(response.status).toBe(200);
      return z.object({ user: z.object({ id: z.string() }) }).parse(await response.json());
    }));
    expect(new Set(sessions.map((value) => value.user.id)).size).toBe(1);
    expect(sessions[0]!.user.id).toMatch(/^user_[0-7][0-9a-hjkmnp-tv-z]{25}$/);
    expect(database.prepare('SELECT count(*) AS count FROM "user"').get()).toEqual({ count: 1 });
    expect(database.prepare("SELECT count(*) AS count FROM account").get()).toEqual({ count: 1 });
    const userID = String(database.prepare('SELECT id FROM "user"').get()!.id);
    expect(userID).toMatch(/^[0-9a-f-]{14}7[0-9a-f-]{21}$/);
    expect(await (await send("/api/v1/admin/members")).json())
      .toMatchObject({ items: [{ id: encodeId("user", userID) }], nextCursor: null });
    expect(await (await send("/api/v1/organizations")).json())
      .toMatchObject({ items: [{ id: encodeId("organization", "01990ab0-0000-7000-8000-000000000001") }], nextCursor: null });

    const organizationID = encodeId("organization", "01990ab0-0000-7000-8000-000000000001");
    const members = z.object({ items: z.array(z.object({ id: z.string(), userId: z.string() })) })
      .parse(await (await send(`/api/v1/organizations/${organizationID}/members`)).json());
    expect(members.items[0]!.id).toMatch(/^omem_/);
    expect(members.items[0]!.userId).toBe(encodeId("user", userID));
    const team = z.object({ id: z.string() }).parse(await (await send(`/api/v1/organizations/${organizationID}/teams`, {
      method: "POST", headers: { origin: config.baseUrl }, body: JSON.stringify({ name: "Round-trip team" }),
    })).json());
    const memberURL = `/api/v1/organizations/${organizationID}/teams/${team.id}/members/${members.items[0]!.userId}`;
    expect((await send(memberURL, { method: "PUT", headers: { origin: config.baseUrl } })).status).toBe(204);
    expect((await send(memberURL, { method: "DELETE", headers: { origin: config.baseUrl } })).status).toBe(204);

    const create = transaction([
      operation("vault", "create", vlt, null, { name: "Vault", createdAt: now }),
      operation("meeting", "create", mtg, null, { projectId: null, name: "Meeting", description: meeting, status: "READY", duration: null,
        recordingStartedAt: null, createdAt: now, updatedAt: now }),
    ]);
    expect(publicSchema("Transaction").safeParse(create).success).toBe(true);
    const v4Transaction = { ...create, id: encodeId("transaction", "00000000-0000-4000-8000-000000000000") };
    expect(publicSchema("Transaction").safeParse(v4Transaction).success).toBe(false);
    expect((await post(v4Transaction)).status).toBe(400);
    const committed = await post(create);
    expect(committed.status).toBe(200);
    const receipt: unknown = await committed.json();
    expect(publicSchema("TransactionReceipt").safeParse(receipt).success).toBe(true);
    expect(receipt).toMatchObject({ id: create.id, records: [ { entity: "vault", id: vlt }, { entity: "meeting", id: mtg } ] });
    expect(await (await post(create)).json()).toEqual(receipt);
    const invalidID = await send(`/api/v1/vaults/${vault}`);
    expect(invalidID.status).toBe(400);
    expect(invalidID.headers.get("content-type")).toContain("application/problem+json");
    expect(await invalidID.json()).toMatchObject({ status: 400, code: "invalid_public_id" });
    expect((await send(`/api/v1/vaults/${mtg}`)).status).toBe(400);
    expect((await send(`/api/v1/vaults/${vlt}`, { method: "HEAD" })).status).toBe(200);
    const vaultResponse = await (await send(`/api/v1/vaults/${vlt}`)).json();
    expect(publicSchema("Vault").safeParse(vaultResponse).success).toBe(true);
    expect(publicSchema("Vault").safeParse({ ...vaultResponse as object, vaultId: vault }).success).toBe(false);
    expect(database.prepare("SELECT meeting_id, vault_id, description FROM meetings").get()).toEqual({ meeting_id: meeting, vault_id: vault, description: meeting });
    expect((await post(transaction([operation("meeting", "delete", meeting, 1, {})]))).status).toBe(400);
    const staleRevision = await post(transaction([operation("meeting", "delete", mtg, 999, {})]));
    expect(staleRevision.status).toBe(409);
    expect(publicSchema("Problem").safeParse(await staleRevision.json()).success).toBe(true);

    const bytes = new TextEncoder().encode("opaque file bytes");
    const reserved = await send("/api/v1/file-uploads", {
      method: "POST", body: JSON.stringify({ id: fileID, vaultId: vlt, name: "note.txt", contentType: "text/plain", metadata: { source: "upload" } }),
    });
    expect(reserved.status).toBe(201);
    const uploaded = await send(`/api/v1/file-uploads/${fileID}/content`, {
      method: "PUT", body: bytes, headers: { "content-type": "application/octet-stream", "content-length": String(bytes.length) },
    });
    expect(uploaded.status).toBe(201);
    const metadata = z.object({ id: z.string(), checksum: z.string(), contentUrl: z.string() }).parse(await uploaded.json());
    expect(metadata.id).toBe(fileID);
    expect(metadata.contentUrl).toBe(`/api/v1/files/${fileID}/content`);
    expect((await post(transaction([
      operation("file", "upsert", fileID, null, { checksum: metadata.checksum, metadata: {} }),
      operation("meeting_attachment", "upsert", att, null, { meetingId: mtg, fileId: fileID, capturedAt: null, sessionId: null, createdAt: now }),
    ]))).status).toBe(200);
    const fileResponse = await (await send(`/api/v1/files/${fileID}`)).json();
    expect(publicSchema("File").safeParse(fileResponse).success).toBe(true);
    const detail = z.object({ id: z.string(), vaultId: z.string(), contentUrl: z.string() }).parse(fileResponse);
    expect(detail).toMatchObject({ id: fileID, vaultId: vlt, contentUrl: `/api/v1/files/${fileID}/content` });
    expect(await (await send(detail.contentUrl)).text()).toBe("opaque file bytes");
    expect(await (await send(metadata.contentUrl)).text()).toBe("opaque file bytes");
    expect(await (await send(`/api/v1/meetings/${mtg}/files`)).json())
      .toMatchObject({ items: [{ id: att, fileId: fileID, meetingId: mtg, file: { id: fileID } }] });
    expect(database.prepare("SELECT id, file_id, meeting_id FROM meeting_attachments").get()).toEqual({ id: attachment, file_id: file, meeting_id: meeting });
    expect(String(database.prepare("SELECT uri FROM files").get()!.uri)).toContain(file);

    // Keep the actual service cursor/auth checks; deterministic rows isolate the transport from FTS ranking.
    const withIdentity = store.sync.withIdentity.bind(store.sync);
    const rowIDs = [attachment, uuidV7()];
    store.sync.withIdentity = (identity, action) => withIdentity(identity, (scoped) => action({
      ...scoped,
      searchTextPage: (_vault, _query, _kind, offset, limit) => Promise.resolve(rowIDs.slice(offset, offset + limit)
        .map((id) => ({ id, meetingId: meeting, snippet: "needle" }))),
    }));
    try {
      for (const kind of ["meeting", "screenshot"] as const) {
        const search = (cursor?: string) => send(`/api/v1/vaults/${vlt}/text-search`, {
          method: "POST", body: JSON.stringify({ query: "needle", kind, limit: 1, ...(cursor ? { cursor } : {}) }),
        });
        const page = z.object({ items: z.array(z.object({ id: z.string(), meetingId: z.string() })), nextCursor: z.string().nullable() });
        const first = page.parse(await (await search()).json());
        expect(first.items[0]).toMatchObject({ id: encodeId(kind === "screenshot" ? "attachment" : "meeting", rowIDs[0]!), meetingId: mtg });
        expect(first.nextCursor).not.toBeNull();
        const cursor = z.tuple([z.string(), z.string(), z.string(), z.number(), z.number()]).parse(JSON.parse(first.nextCursor!));
        expect(cursor[0]).toBe(vlt);
        const next = await search(first.nextCursor!);
        expect(next.status).toBe(200);
        expect(page.parse(await next.json())).toMatchObject({ items: [{ id: encodeId(kind === "screenshot" ? "attachment" : "meeting", rowIDs[1]!) }], nextCursor: null });
        cursor[3] += 1;
        expect((await search(JSON.stringify(cursor))).status).toBe(409);
        expect((await search("invalid")).status).toBe(400);
      }
    } finally { store.sync.withIdentity = withIdentity; }

    const chunk = JSON.stringify({ segments: [{ segmentId: encodeId("segment", segment), startedAt: now, endedAt: null, text: meeting, createdAt: now, audioSource: null, speakerLabel: null }], deletions: [] });
    const hash = createHash("sha256").update(chunk).digest("hex");
    const chunkURL = `/api/v1/meetings/${mtg}/transcript-uploads/${encodeId("patch", patch)}/chunks/0`;
    const rejectedChunk = await send(chunkURL, { method: "PUT", headers: { "x-dahlia-content-sha256": "0".repeat(64) }, body: chunk });
    expect(rejectedChunk.status, await rejectedChunk.text()).toBe(409);
    const acceptedChunk = await send(chunkURL, { method: "PUT", headers: { "x-dahlia-content-sha256": hash }, body: chunk });
    expect(acceptedChunk.status, await acceptedChunk.text()).toBe(204);
    const missingMeeting = encodeId("meeting", uuidV7());
    const missingChunk = await send(chunkURL.replace(mtg, missingMeeting), {
      method: "PUT", headers: { "x-dahlia-content-sha256": hash }, body: chunk,
    });
    expect(missingChunk.status).toBe(409);
    const missingProblem = await missingChunk.json();
    expect(missingProblem).toMatchObject({ conflicts: [{ id: missingMeeting }] });
    expect(publicSchema("Problem").safeParse(missingProblem).success).toBe(true);
    const stored = database.prepare("SELECT content_hash, payload FROM transcript_patch_chunks").get()!;
    expect(stored.content_hash).toBe(hash);
    expect(JSON.parse(String(stored.payload))).toMatchObject({ segments: [{ segmentId: segment, text: meeting }] });
    const transcriptCommit = await post(transaction([operation("transcript", "patch", mtg, 0, {
      transcript: { id: encodeId("transcript", transcript), startedAt: now, endedAt: null, metadata: null }, mode: "replace", patchId: encodeId("patch", patch),
      segmentCount: 1, deletionCount: 0, chunks: [{ index: 0, sha256: hash, segmentCount: 1, deletionCount: 0 }],
    })]));
    expect(transcriptCommit.status, await transcriptCommit.text()).toBe(200);
    expect(await (await send(`/api/v1/meetings/${mtg}/transcripts`)).json())
      .toMatchObject({ items: [{ id: encodeId("transcript", transcript), meetingId: mtg }] });
    expect(await (await send(`/api/v1/meetings/${mtg}/transcripts/1`)).json())
      .toMatchObject({ items: [{ segmentId: encodeId("segment", segment), text: meeting }] });
    const document = `{ "sections": [{"id":"${meeting}","blocks":[{"id":"${file}","type":"image","screenshot_id":"${att}","content":{"text":"${meeting}"}}]}] }`;
    const summaryCommit = await post(transaction([operation("summary", "upsert", mtg, 0, { title: "Summary", document, createdAt: now })]));
    expect(summaryCommit.status, await summaryCommit.text()).toBe(200);
    const summary = z.object({ id: z.string(), meetingId: z.string(), document: z.string() }).parse(await (await send(`/api/v1/meetings/${mtg}/summaries/1`)).json());
    expect(summary.id).toMatch(/^sum_/);
    expect(summary.meetingId).toBe(mtg);
    expect(summary.document).toBe(document);
    expect(database.prepare("SELECT document FROM summaries").get()).toEqual({ document: document.replace(att, attachment) });
    const mcp = async (name: string, args: unknown) => {
      const body = JSON.stringify({ jsonrpc: "2.0", id: "opaque-jsonrpc-id", method: "tools/call", params: { name, arguments: args,
        _meta: { "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": { name: "TypeID test", version: "1" },
          "io.modelcontextprotocol/protocolVersion": "2026-07-28" } } });
      return (await send("/mcp", { method: "POST", body, headers: { "content-length": String(new TextEncoder().encode(body).length),
        "mcp-method": "tools/call", "mcp-name": name, "mcp-protocol-version": "2026-07-28" } })).json();
    };
    const mcpResponse = z.object({ id: z.string(), result: z.object({ content: z.array(z.object({ text: z.string() })) }) });
    const mcpMeeting = mcpResponse.parse(await mcp("get_meeting", { vault_id: vlt, meeting_id: mtg }));
    expect(mcpMeeting.id).toBe("opaque-jsonrpc-id");
    expect(JSON.parse(mcpMeeting.result.content[0]!.text)).toMatchObject({ meetingId: mtg, vaultId: vlt });
    const mcpTranscript = mcpResponse.parse(await mcp("get_meeting_transcript", { vault_id: vlt, meeting_id: mtg }));
    expect(JSON.parse(mcpTranscript.result.content[0]!.text)).toMatchObject({ items: [{ segmentId: encodeId("segment", segment) }] });
    expect(await mcp("get_meeting", { vault_id: vault, meeting_id: mtg })).toMatchObject({ result: { isError: true } });
    const conflict = await post(transaction([operation("meeting", "delete", mtg, 99, {})]));
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toMatchObject({ conflicts: [{ entity: "meeting", id: mtg }] });
    expect(database.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
  } finally {
    database.close();
    await store.close?.();
    rmSync(directory, { recursive: true, force: true });
  }
});

it("resolves D1 header subjects atomically without linking matching emails", async () => {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-d1-identity-"));
  const path = join(directory, "empty.sqlite");
  const store = createNodeApplicationStore({ authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${path}`,
    baseUrl: "https://public.example", oauthRedirectUris: [], maxRequestBytes: 1024 });
  await store.migrate();
  const database = new DatabaseSync(path);
  class Statement implements D1PreparedStatementLike {
    values: SQLInputValue[] = [];
    constructor(readonly query: string) {}
    bind(...values: unknown[]) { this.values = values as SQLInputValue[]; return this; }
    async first<T>() { return database.prepare(this.query).get(...this.values) as T ?? null; }
    async all<T>() { return { results: database.prepare(this.query).all(...this.values) as T[] }; }
    async run() { return { meta: { changes: Number(database.prepare(this.query).run(...this.values).changes) } }; }
  }
  const d1 = createD1ApplicationStore({ prepare: (query) => new Statement(query), async batch(statements) {
    database.exec("BEGIN");
    try {
      const results = statements.map((statement) => {
        const value = statement as Statement;
        return database.prepare(value.query).run(...value.values);
      });
      database.exec("COMMIT");
      return results;
    } catch (error) { database.exec("ROLLBACK"); throw error; }
  } });
  const identity = { userId: "subject-one", email: "same@example.com", workspaceId: "personal:subject-one", source: "header" as const };
  try {
    const ids = await Promise.all(Array.from({ length: 12 }, () => d1.resolveHeaderUser(identity)));
    expect(ids[0]).toMatch(/^[0-9a-f-]{36}$/);
    expect(new Set(ids).size).toBe(1);
    expect(await d1.resolveHeaderUser({ ...identity, userId: "subject-two" })).toBeNull();
    expect(await d1.resolveHeaderUser(identity)).toBe(ids[0]);
    expect(database.prepare('SELECT count(*) AS count FROM "user"').get()).toEqual({ count: 1 });
    expect(database.prepare("SELECT count(*) AS count FROM account").get()).toEqual({ count: 1 });
    expect(database.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
  } finally { database.close(); await store.close?.(); rmSync(directory, { recursive: true, force: true }); }
});

it("keeps Better Auth sessions, organizations, teams and invitations typed at the public boundary", async () => {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-public-auth-"));
  const path = join(directory, "empty.sqlite");
  const config = { authProvider: "accounts" as const, authHeader: "X-Forwarded-Email", databaseType: "sqlite" as const,
    databaseUrl: `file:${path}`, baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1048576,
    betterAuthSecret: "test-only-public-ids-secret-value", googleClientId: "test-client", googleClientSecret: "test-secret" };
  const store = createNodeApplicationStore(config);
  await store.migrate();
  const auth = await initializeDahliaAuth(config, store);
  const context = await auth.$context;
  const user = await context.internalAdapter.createUser({ name: "Owner", email: "owner@example.com", emailVerified: true }, { method: "email-password" });
  const session = await context.internalAdapter.createSession(user.id, false);
  const signature = createHmac("sha256", config.betterAuthSecret).update(session.token).digest("base64");
  const cookie = `${context.authCookies.sessionToken.name}=${encodeURIComponent(`${session.token}.${signature}`)}`;
  const app = createApp({ config, authStore: store, auth });
  const send = (path: string, body?: unknown, sessionCookie = cookie) => app.request(`${config.baseUrl}${path}`, {
    method: body === undefined ? "GET" : "POST", headers: { cookie: sessionCookie, origin: config.baseUrl, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const post = async (path: string, body: unknown) => {
    const response = await send(`/api/auth/organization/${path}`, body);
    const value: unknown = await response.json();
    expect(response.status, JSON.stringify(value)).toBe(200);
    return z.object({ id: z.string() }).passthrough().parse(value);
  };
  const database = new DatabaseSync(path);
  try {
    expect(user.id).toMatch(/^[0-9a-f-]{14}7[0-9a-f-]{21}$/);
    expect(await (await send("/api/auth/get-session")).json()).toMatchObject({
      user: { id: encodeId("user", user.id) }, session: { id: encodeId("session", session.id), userId: encodeId("user", user.id), token: session.token },
    });
    const organization = await post("create", { name: "TypeID Org", slug: "typeid-org" });
    expect(organization.id).toMatch(/^org_/);
    const team = await post("create-team", { organizationId: organization.id, name: "Reviewers" });
    expect(team.id).toMatch(/^team_/);
    const teamMember = await post("add-team-member", { teamId: team.id, userId: encodeId("user", user.id) });
    expect(teamMember.id).toMatch(/^tmem_/);
    expect(await (await send("/api/auth/organization/set-active-team", { teamId: team.id })).json()).toMatchObject({ id: team.id });
    expect((await send("/api/auth/organization/set-active-team", { teamId: decodeId("team", team.id) })).status).toBe(400);
    expect(await (await send(`/api/auth/organization/get-organization?organizationId=${organization.id}`)).json()).toMatchObject({ id: organization.id });
    const memberPage = z.object({ members: z.array(z.object({ id: z.string() })) }).parse(
      await (await send(`/api/auth/organization/list-members?organizationId=${organization.id}`)).json());
    const memberID = memberPage.members[0]!.id;
    expect(await (await send(`/api/auth/organization/list-members?organizationId=${organization.id}&filterField=id&filterValue=${memberID}`)).json())
      .toMatchObject({ members: [{ id: memberID }] });
    expect((await send(`/api/auth/organization/list-members?organizationId=${organization.id}&filterField=id&filterValue=${decodeId("organizationMember", memberID)}`)).status).toBe(400);
    const vaultID = encodeId("vault", uuidV7());
    const createdVault = await send("/api/v1/transactions", { schemaVersion: 2, createdAt: new Date().toISOString(), id: encodeId("transaction", uuidV7()), vaultId: vaultID,
      operations: [{ id: encodeId("operation", uuidV7()), entity: "vault", entityId: vaultID, action: "create", baseRevision: null,
        data: { name: "Sharing", createdAt: new Date().toISOString() } }] });
    expect(createdVault.status, await createdVault.text()).toBe(200);
    for (const [path, principalID] of [["organizations", organization.id], ["teams", team.id]] as const) {
      const permissionURL = `${config.baseUrl}/api/v1/vaults/${vaultID}/permissions/${path}/${principalID}`;
      const headers = { cookie, origin: config.baseUrl };
      const granted = await app.request(permissionURL, { method: "PUT", headers });
      expect(granted.status, await granted.text()).toBe(204);
      expect((await app.request(permissionURL, { method: "PUT", headers })).status).toBe(204);
      expect(await (await send(`/api/v1/vaults/${vaultID}/permissions`)).json())
        .toMatchObject({ items: expect.arrayContaining([{ vaultId: vaultID, principalId: principalID,
          principalType: path === "teams" ? "team" : "organization", role: "member", createdAt: expect.any(String) as unknown }]) as unknown });
      expect((await app.request(permissionURL, { method: "DELETE", headers })).status).toBe(204);
      expect((await app.request(permissionURL.replace(vaultID, decodeId("vault", vaultID)), { method: "PUT", headers })).status).toBe(400);
    }
    const second = await post("create-team", { organizationId: organization.id, name: "Editors" });
    const invitation = await post("invite-member", { organizationId: organization.id, email: "invitee@example.com", role: "member", teamId: [team.id, second.id] });
    expect(invitation.id).toMatch(/^inv_/);
    expect(invitation.teamId).toBe(`${team.id},${second.id}`);
    expect(invitation.inviterId).toBe(encodeId("user", user.id));
    expect((await send(`/api/auth/organization/get-invitation?id=${user.id}`)).status).toBe(400);
    const recipient = await context.internalAdapter.createUser({ name: "Invitee", email: "invitee@example.com", emailVerified: true }, { method: "email-password" });
    const recipientSession = await context.internalAdapter.createSession(recipient.id, false);
    const recipientSignature = createHmac("sha256", config.betterAuthSecret).update(recipientSession.token).digest("base64");
    const recipientCookie = `${context.authCookies.sessionToken.name}=${encodeURIComponent(`${recipientSession.token}.${recipientSignature}`)}`;
    expect(await (await send(`/api/auth/organization/get-invitation?id=${invitation.id}`, undefined, recipientCookie)).json()).toMatchObject({ id: invitation.id });
    expect(await (await send(`/api/auth/organization/list-invitations?organizationId=${organization.id}`)).json())
      .toMatchObject([{ id: invitation.id, teamId: invitation.teamId }]);
    expect((await send("/api/auth/organization/create-team", { organizationId: user.id, name: "Invalid" })).status).toBe(400);
    expect(await post("cancel-invitation", { invitationId: invitation.id })).toMatchObject({ id: invitation.id });
    for (const action of ["reject", "accept"] as const) {
      const pending = await post("invite-member", { organizationId: organization.id, email: recipient.email, role: "member", teamId: [team.id, second.id] });
      const response = await send(`/api/auth/organization/${action}-invitation`, { invitationId: pending.id }, recipientCookie);
      const body: unknown = await response.json();
      expect(response.status, JSON.stringify(body)).toBe(200);
      expect(body).toMatchObject({ invitation: { id: pending.id, organizationId: organization.id,
        inviterId: encodeId("user", user.id), teamId: `${team.id},${second.id}`, status: `${action}ed` } });
      if (action === "reject") expect(body).toMatchObject({ member: null });
      else expect(body).toMatchObject({ member: { id: expect.stringMatching(/^omem_/) as unknown,
        organizationId: organization.id, userId: encodeId("user", recipient.id) } });
    }
    expect((await send("/api/auth/organization/remove-team-member", { teamId: team.id, userId: encodeId("user", user.id) })).status).toBe(200);
    expect(await (await send("/api/auth/organization/set-active-team", { teamId: null })).json()).toBeNull();
    const removedTeam = await send("/api/auth/organization/remove-team", { organizationId: organization.id, teamId: team.id });
    expect(removedTeam.status, await removedTeam.text()).toBe(200);
    await context.internalAdapter.updateUser(user.id, { role: "admin" });
    const recipientID = encodeId("user", recipient.id);
    expect(await (await send(`/api/auth/admin/get-user?id=${recipientID}`)).json()).toMatchObject({ id: recipientID });
    expect((await send(`/api/auth/admin/get-user?id=${recipient.id}`)).status).toBe(400);
    expect(await (await send("/api/auth/admin/update-user", { userId: recipientID, data: { name: "Updated" } })).json())
      .toMatchObject({ id: recipientID, name: "Updated" });
    expect(await (await send(`/api/auth/admin/list-users?filterField=id&filterValue=${recipientID}`)).json())
      .toMatchObject({ users: [{ id: recipientID }] });
    expect((await send(`/api/auth/admin/list-users?filterField=id&filterValue=${recipient.id}`)).status).toBe(400);
    expect(await (await send("/api/auth/admin/list-user-sessions", { userId: recipientID })).json())
      .toMatchObject({ sessions: [{ id: encodeId("session", recipientSession.id), userId: recipientID, token: recipientSession.token }] });
    expect((await send("/api/auth/admin/revoke-user-sessions", { userId: recipient.id })).status).toBe(400);
    expect((await send("/api/auth/admin/revoke-user-sessions", { userId: recipientID })).status).toBe(200);
    expect(database.prepare("SELECT user_id, token FROM session").get()).toMatchObject({ user_id: user.id, token: session.token });
    expect(String(database.prepare("SELECT team_id FROM invitation").get()!.team_id)).not.toContain("team_");
    expect(database.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
  } finally { database.close(); await store.close?.(); rmSync(directory, { recursive: true, force: true }); }
});
