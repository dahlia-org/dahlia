import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createNodeApplicationStore, type NodeApplicationStore } from "../src/auth/node-store";
import { uuidV7 } from "../src/id";
import { MeetingSyncService } from "../src/sync/service";
import { DEFAULT_SEARCH_SETTINGS } from "../src/search/settings-model";
import type { AppConfig } from "../src/config";
import { Pool } from "pg";
import { drizzle } from "drizzle-orm/node-postgres";
import { createPostgresMeetingSyncStore } from "../src/sync/store";
import { ensureSearchIndexes } from "../src/db/client";

const resources: Array<{ store: NodeApplicationStore; directory: string }> = [];
afterEach(async () => {
  for (const { store, directory } of resources.splice(0)) {
    await store.close?.();
    rmSync(directory, { recursive: true, force: true });
  }
});

// Both URLs must point to dedicated disposable databases; Lakebase Search must be enabled by the operator.
describe.each(["sqlite", "postgres", "lakebase"] as const)("%s weighted search", (backend) => {
  const databaseUrl = backend === "lakebase" ? process.env.TEST_SEARCH_LAKEBASE_URL : process.env.TEST_SEARCH_DATABASE_URL;
  const test = backend === "sqlite" ? it : it.runIf(databaseUrl);
  async function setup() {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-search-weights-"));
    const path = join(directory, "app.sqlite");
    const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: backend === "sqlite" ? "sqlite" : "postgres",
      databaseUrl: backend === "sqlite" ? `file:${path}` : databaseUrl,
      baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024 };
    const store = createNodeApplicationStore(config);
    resources.push({ store, directory });
    await store.migrate();
    let lakebase: Pool | undefined;
    if (backend === "lakebase") {
      // A cutoff of one catches accidental per-field top-K truncation before weighted ranking.
      lakebase = new Pool({ connectionString: databaseUrl, max: 1, options: "-c search_path=app,auth -c lakebase_bm25.default_limit=1" });
      const close = store.close!.bind(store);
      store.close = async () => { await lakebase!.end(); await close(); };
      await ensureSearchIndexes(lakebase, { ...config, databaseType: "lakebase" });
      store.sync = createPostgresMeetingSyncStore(drizzle({ client: lakebase }), "lakebase");
    }
    await store.searchSettings.update(DEFAULT_SEARCH_SETTINGS);
    const externalId = uuidV7();
    const userId = (await store.resolveHeaderUser({ userId: externalId,  source: "header", email: `${externalId}@example.test` }))!;
    const owner = { userId,  source: "header" as const };
    await store.ensureIdentityUser(owner);
    const testOrganizationID = (await store.listServerOrganizations(100, 0)).find((org) => org.name === "example.test")!.id;
    const workspaceId = uuidV7();
    const service = new MeetingSyncService(store.sync);
    const commit = (operations: Array<Record<string, unknown>>) => service.commitTransaction(owner, {
      schemaVersion: 3, id: uuidV7(), workspaceId, createdAt: new Date().toISOString(),
      operations: operations.map((operation) => ({ ...operation, id: uuidV7() })),
    });
    await commit([{ entity: "workspace", action: "create", entityId: workspaceId, baseRevision: null, data: { organizationId: testOrganizationID, name: "Search", createdAt: new Date().toISOString() } }]);
    const meetingData = (name: string, description: string) => ({ name, description, projectId: null, status: "READY", duration: null, recordingStartedAt: null,
      createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() });
    const add = async (name: string, description = "", document?: string) => {
      const id = uuidV7();
      await commit([{ entity: "meeting", action: "create", entityId: id, baseRevision: null, data: meetingData(name, description) },
        ...(document ? [{ entity: "summary", action: "upsert", entityId: id, baseRevision: 0,
          data: { title: name, document, createdAt: new Date().toISOString() } }] : [])]);
      return id;
    };
    const search = async (query: string) => {
      if (lakebase) await lakebase.query("VACUUM ANALYZE search.documents");
      return (await service.listMeetings(owner, workspaceId, query)).items.map((meeting) => meeting.meetingId);
    };
    return { store, service, owner, workspaceId, path, config, commit, add, search, meetingData };
  }

  test("changes ranking immediately, matches across fields and retains access checks", async () => {
    const { store, service, owner, workspaceId, add, search } = await setup();
    const title = await add("needle", "filler");
    const description = await add("filler", "needle");
    expect(await search("needle")).toEqual([title, description]);
    await store.searchSettings.update({ ...DEFAULT_SEARCH_SETTINGS, title: 1, description: 10 });
    expect(await search("needle")).toEqual([description, title]);
    expect(await search("needle filler")).toHaveLength(2);
    const japanese = await add("契約", "更新");
    expect(await search("契約 更新")).toEqual([japanese]);
    const other = { ...owner, userId: uuidV7() };
    await store.ensureIdentityUser(other);
    expect((await service.listMeetings(other, workspaceId, "needle")).items).toEqual([]);
    expect(await store.searchSettings.get()).toMatchObject({ title: 1, description: 10 });
    expect(await search("needle")).toEqual([description, title]);
  });

  test("indexes summary tags and updates search snippets on tag-only edits", async () => {
    const { store, service, owner, workspaceId, add, search, commit } = await setup();
    const document = (tags: string[]) => JSON.stringify({ schemaVersion: 3, title: "Meeting", description: "", tags, actionItems: [],
      sections: [{ heading: "", blocks: [{ type: "paragraph", content: { text: "Stable summary" } }] }] });
    const id = await add("Meeting", "", document(["budget"]));
    const unrelated = await add("Unrelated");
    expect((await service.getMeeting(owner, workspaceId, unrelated))?.summaryDocument).toBeNull();
    expect(await search("budget")).toEqual([id]);
    expect(await search("budget stable")).toEqual([id]);
    const before = await store.sync.withIdentity(owner, (scoped) => scoped.searchTextPage(workspaceId, { text: "budget", tokens: ["budget"] }, "meeting", 0, 10));
    await commit([{ entity: "summary", action: "upsert", entityId: id, baseRevision: 1,
      data: { title: "Meeting", document: document(["roadmap"]), createdAt: new Date().toISOString() } }]);
    expect(await search("budget")).toEqual([]);
    expect(await search("roadmap")).toEqual([id]);
    const after = await store.sync.withIdentity(owner, (scoped) => scoped.searchTextPage(workspaceId, { text: "roadmap", tokens: ["roadmap"] }, "meeting", 0, 10));
    expect(before[0]?.snippet).toContain("budget");
    expect(after[0]?.snippet).toContain("roadmap");
    await commit([{ entity: "summary", action: "delete", entityId: id, baseRevision: 2, data: {} }]);
    expect(await search("roadmap")).toEqual([]);
    expect(await search("stable")).toEqual([]);
    await commit([{ entity: "meeting", action: "delete", entityId: id, baseRevision: 1, data: {} }]);
    expect(await search("meeting")).toEqual([]);
  });

  test("applies weights before limiting candidates", async () => {
    const { add, store, search } = await setup();
    for (let index = 0; index < 101; index++) await add("needle", "filler");
    const winner = await add("filler", "needle");
    await store.searchSettings.update({ ...DEFAULT_SEARCH_SETTINGS, title: 1, description: 10 });
    const result = await search("needle");
    expect(result).toHaveLength(100);
    expect(result[0]).toBe(winner);
  });

  if (backend === "sqlite") it("persists search weights across store restart", async () => {
    const { store, config } = await setup();
    await store.searchSettings.update({ ...DEFAULT_SEARCH_SETTINGS, title: 9 });
    const reopened = createNodeApplicationStore(config);
    try { expect(await reopened.searchSettings.get()).toMatchObject({ title: 9 }); }
    finally { await reopened.close?.(); }
  });
});
