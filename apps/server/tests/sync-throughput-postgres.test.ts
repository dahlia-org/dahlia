import { expect, it } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "@dahlia-ai/ui/model/id";
import { seedPostgresIdentity, testOrganizationID } from "./public-test-client";

// Opt-in: two disposable Workspaces, 10,000 logical operations per run; no live QA data.
it.runIf(process.env.TEST_SYNC_LOAD_DATABASE_URL)("measures bounded initial batches and foreground latency under import", async () => {
  const url = process.env.TEST_SYNC_LOAD_DATABASE_URL!;
  const store = createNodeApplicationStore({ authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "postgres",
    databaseUrl: url, baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576 });
  const owner = { userId: uuidV7(), source: "header" as const };
  const sync = new MeetingSyncService(store.sync);
  const meetingId = uuidV7(), single = uuidV7(), batched = uuidV7();
  const now = new Date().toISOString();
  const envelope = (workspaceId: string, operations: unknown[]) => ({ id: uuidV7(), schemaVersion: 3, workspaceId, createdAt: now, operations });
  const p95 = (values: number[]) => values.toSorted((a, b) => a - b)[Math.ceil(values.length * .95) - 1]!;
  let revision = 1;
  async function edit() {
    const started = performance.now();
    await sync.commitTransaction(owner, envelope(batched, [{ id: uuidV7(), entity: "meeting", action: "update", entityId: meetingId,
      baseRevision: revision++, data: { name: "Edited", projectId: null, description: "", status: "READY", duration: null,
        recordingStartedAt: null, updatedAt: now } }]));
    return performance.now() - started;
  }
  async function importProjects(workspaceId: string, size: number, sample = false) {
    const started = performance.now(), pending: Promise<number>[] = [];
    let sampleTask = Promise.resolve(0), sampled = 0;
    for (let index = 0; index < 10_000; index += size) {
      if (sample && sampled < 30 && index >= sampled * 333) {
        // Keep edits ordered while allowing them to overlap the background writer.
        sampleTask = sampleTask.then(edit); pending.push(sampleTask); sampled++;
      }
      await sync.commitTransaction(owner, envelope(workspaceId, Array.from({ length: Math.min(size, 10_000 - index) }, () => ({
        id: uuidV7(), entity: "project", action: "create", entityId: uuidV7(), baseRevision: null,
        data: { parentProjectId: null, name: "Imported", description: "", projectType: "undefined", createdAt: now },
      }))));
    }
    return { milliseconds: performance.now() - started, edits: await Promise.all(pending) };
  }
  try {
    await store.migrate(); await seedPostgresIdentity(store, url, owner);
    for (const workspaceId of [single, batched]) {
      await sync.commitTransaction(owner, envelope(workspaceId, [{ id: uuidV7(), entity: "workspace", action: "create", entityId: workspaceId,
        baseRevision: null, data: { organizationId: testOrganizationID, name: "Load fixture", encryption: "none", createdAt: now } }]));
    }
    await sync.commitTransaction(owner, envelope(batched, [{ id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId,
      baseRevision: null, data: { name: "Meeting", projectId: null, description: "", status: "READY", duration: null,
        recordingStartedAt: null, createdAt: now, updatedAt: now } }]));
    await edit(); // Warm the same route before collecting the idle baseline.
    const idle: number[] = [];
    for (let index = 0; index < 30; index++) idle.push(await edit());
    const baseline = await importProjects(single, 1);
    const optimized = await importProjects(batched, 8, true);
    process.stdout.write("sync_import_10000 " + JSON.stringify({ singleMs: baseline.milliseconds, batchMs: optimized.milliseconds,
      idleEditP95Ms: p95(idle), loadedEditP95Ms: p95(optimized.edits) }) + "\n");
    expect(optimized.edits).toHaveLength(30);
    let cursor: string | undefined, start: string | undefined, projects = 0;
    do {
      const page = await sync.listSnapshot(owner, batched, cursor, start);
      projects += page.items.filter((item) => item.entity === "project").length;
      cursor = page.nextCursor ?? undefined; start = page.startCursor;
    } while (cursor);
    expect(projects).toBe(10_000);
    // Performance is reported rather than asserted against noisy wall-clock thresholds.
  } finally { await store.close?.(); }
}, 600_000);
