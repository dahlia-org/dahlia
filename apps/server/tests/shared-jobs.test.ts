import { drizzle } from "drizzle-orm/sqlite-proxy";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { eq } from "drizzle-orm";
import * as sqliteSchema from "../src/db/sqlite-schema";
import type * as pgSchema from "../src/db/auth-schema";
const schema = sqliteSchema as unknown as typeof pgSchema;
import { cancelJobs, enqueueJob, lockJob } from "../src/jobs/state";
import { testJobPayload } from "./fixtures/job-payload";
import { fork } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { serverMigrationManifest } from "../src/migrations";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { defaultJobLimits, jobKinds, loadJobConfig } from "../src/jobs/model";
import { jobResources } from "../src/jobs/resources";
import { JobRunner } from "../src/jobs/node-runner";
import { createJobExecutor } from "../src/jobs/execute";
const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { vi.useRealTimers(); for (const close of cleanup.splice(0)) await close(); });
async function fixture() {
  const path = mkdtempSync(join(tmpdir(), "dahlia-jobs-"));
  const url = `file:${join(path, "test.sqlite")}`;
  const store = createNodeApplicationStore({ authProvider: "header", authHeader: "x-forwarded-email", databaseType: "sqlite", databaseUrl: url,
    baseUrl: "http://localhost", oauthRedirectUris: [], maxRequestBytes: 1024,
    jobs: { workers: "auto", concurrency: "auto", limits: { ...defaultJobLimits, image: 1 } } }, serverMigrationManifest);
  await store.migrate();
  const db = new DatabaseSync(join(path, "test.sqlite"));
  cleanup.push(async () => { db.close(); await store.close?.(); rmSync(path, { recursive: true, force: true }); });
  const sqlDb = drizzle(async (query, params, method) => {
    const statement = db.prepare(query);
    statement.setReturnArrays(true);
    if (method === "run") { statement.run(...params as []); return { rows: [] }; }
    return { rows: statement.all(...params as []) };
  }) as unknown as NodePgDatabase;
  return { queue: store.jobs, db, url, sqlDb };

}
describe("shared durable dispatch", () => {
  it("lets waiting memory run ahead of an older image after its retry becomes due", async () => {
    const { queue, db } = await fixture();
    await queue.enqueue("image", "image", "owner", "file", testJobPayload("image"));
    await queue.enqueue("memory", "workspace-memory", "owner", "memory", testJobPayload("workspace-memory"));
    db.exec("UPDATE jobs_queue SET created_at = CASE WHEN dedupe_key = 'image' THEN 1000 ELSE 2000 END, available_at = 0");
    const image = (await queue.claim(["image", "workspace-memory"]))!;
    expect(image.dedupeKey).toBe("image");
    await queue.reschedule(image, image.payload, 0);
    expect((await queue.claim(["image", "workspace-memory"]))!.dedupeKey).toBe("memory");
  });
  it("runs memory before rechecking an older image whose source is not ready", async () => {
    const { queue, db } = await fixture();
    vi.useFakeTimers();
    await queue.enqueue("image", "image", "owner", "file", { ...testJobPayload("image"), model: "model" });
    const memoryPayload = testJobPayload("workspace-memory");
    await queue.enqueue("memory", "workspace-memory", "owner", "memory", memoryPayload);
    db.exec("UPDATE jobs_queue SET created_at = CASE WHEN dedupe_key = 'image' THEN 1000 ELSE 2000 END");
    const claim = vi.fn(async (_model: string, job: import("../src/jobs/store").BackgroundJob) => {
      await queue.retry(job, { delayMs: 60_000, errorCode: "job_source_not_ready" });
      return null;
    }), step = vi.fn().mockResolvedValue(undefined);
    const executor = createJobExecutor({ queue,
      summaryJobs: {} as never, methods: [], sync: {} as never, syncStore: {} as never,
      imageAnalysis: { claim } as never, captioner: { model: "model" } as never, memory: { step } as never });
    const signal = new AbortController().signal;
    await executor.processOne(signal);
    expect(claim).toHaveBeenCalledOnce();
    vi.setSystemTime(Date.now() + 2_000);
    await executor.processOne(signal);
    expect(step).toHaveBeenCalledWith(memoryPayload.scopeId, expect.any(AbortSignal), expect.objectContaining({ kind: "workspace-memory" }));
    expect(claim).toHaveBeenCalledOnce();
    expect(await executor.processOne(signal)).toBe(false);
    vi.setSystemTime(Date.now() + 60_000);
    await executor.processOne(signal);
    expect(claim).toHaveBeenCalledTimes(2);
    vi.setSystemTime(Date.now() + 60_000);
    await executor.processOne(signal);
    expect(db.prepare("SELECT status, attempts, dispatch_attempts, last_error FROM jobs_queue WHERE dedupe_key = 'image'").get())
      .toMatchObject({ status: "failed", attempts: 0, dispatch_attempts: 3, last_error: "job_source_not_ready" });
    vi.setSystemTime(Date.now() + 60_000);
    expect(await executor.processOne(signal)).toBe(false);
    expect(claim).toHaveBeenCalledTimes(3);
    await queue.enqueue("image", "image", "owner", "file", { ...testJobPayload("image"), model: "model" });
    await executor.processOne(signal);
    expect(claim).toHaveBeenCalledTimes(4);
    expect(db.prepare("SELECT status, attempts, dispatch_attempts FROM jobs_queue WHERE dedupe_key = 'image'").get())
      .toMatchObject({ status: "pending", attempts: 0, dispatch_attempts: 1 });
  });
  it("revives failed recurring work without replacing pending or active registrations", async () => {
    const { queue, db } = await fixture();
    for (const [id, kind] of [["maintenance", "maintenance"], ["reconcile:image:scope", "reconcile"]] as const) {
      await queue.enqueue(id, kind, "", id, { ...testJobPayload(kind), after: "old" });
      db.prepare("UPDATE jobs_queue SET dispatch_attempts = 2 WHERE dedupe_key = ?").run(id);
      const failed = (await queue.claim([kind]))!;
      await queue.retry(failed);
      expect(db.prepare("SELECT status FROM jobs_queue WHERE dedupe_key = ?").get(id)?.status).toBe("failed");
      await queue.enqueue(id, kind, "", id, { ...testJobPayload(kind), after: "new" });
      await queue.enqueue(id, kind, "", id, { ...testJobPayload(kind), after: "ignored-pending" });
      const revived = (await queue.claim([kind]))!;
      expect(revived).toMatchObject({ attempts: 1, payload: { after: "new" } });
      await queue.enqueue(id, kind, "", id, { ...testJobPayload(kind), after: "ignored-active" });
      expect(await queue.claim([kind])).toBeNull();
      await queue.complete(revived);
    }
  });
  it("retains source-backed dispatch in the DLQ after three infrastructure failures and revives on registration", async () => {
    const { queue, db } = await fixture();
    for (const kind of jobKinds.filter((kind) => kind !== "maintenance" && kind !== "reconcile")) {
      await queue.enqueue(kind, kind, "owner", kind, testJobPayload(kind));
      db.prepare("UPDATE jobs_queue SET attempts = 7, dispatch_attempts = 2 WHERE dedupe_key = ?").run(kind);
      await queue.retry((await queue.claim([kind]))!);
      expect(db.prepare("SELECT status, attempts, dispatch_attempts FROM jobs_queue WHERE dedupe_key = ?").get(kind))
        .toMatchObject({ status: "failed", attempts: 7, dispatch_attempts: 3 });
      expect(await queue.claim([kind])).toBeNull();
      expect(await queue.nextDelay([kind])).toBeUndefined();
      await queue.enqueue(kind, kind, "owner", kind, testJobPayload(kind));
      const recovered = (await queue.claim([kind]))!;
      expect(recovered).toMatchObject({ attempts: 8, dispatchAttempts: 1 });
      await queue.complete(recovered);
    }
  });
  it("enforces caps, target serialization, owner fairness and old-first eligibility", async () => {
    const { queue } = await fixture();
    for (const [id, kind, owner, target] of [
      ["a1", "image", "a", "file1"], ["a2", "image", "a", "file2"], ["b1", "summary", "b", "meeting1"],
      ["b2", "storage-delete", "b", "meeting1"], ["b3", "summary", "b", "meeting2"],
    ] as const) await queue.enqueue(id, kind, owner, target, testJobPayload(kind));
    const first = (await queue.claim(["image", "summary", "storage-delete"]))!;
    expect(first.dedupeKey).toBe("a1");
    const second = (await queue.claim(["image", "summary", "storage-delete"]))!;
    expect(second.dedupeKey).toBe("b1");
    expect((await queue.claim(["image", "summary", "storage-delete"]))!.dedupeKey).toBe("b3");
    expect(await queue.claim(["image", "summary", "storage-delete"])).toBeNull();
    await queue.complete(first);
    expect((await queue.claim(["image", "summary", "storage-delete"]))!.dedupeKey).toBe("a2");
    await queue.complete(second);
    expect((await queue.claim(["image", "summary", "storage-delete"]))!.dedupeKey).toBe("b2");
  });
  it("preserves newer work and rejects completion from an expired lease", async () => {
    const { queue, db } = await fixture();
    await queue.enqueue("one", "summary", "a", "meeting", testJobPayload("summary"));
    const first = (await queue.claim(["summary"]))!;
    db.exec("UPDATE jobs_queue SET generation = generation + 1");
    await queue.complete(first);
    const next = (await queue.claim(["summary"]))!;
    expect(next.generation).toBe(2);
    expect(next.attempts).toBe(2);
    db.exec("UPDATE jobs_queue SET lease_until = 0");
    const retry = (await queue.claim(["summary"]))!;
    expect(retry.lease).not.toBe(next.lease);
    await queue.complete(next);
    expect(await queue.claim(["summary"])).toBeNull();
    await queue.complete(retry);
    expect(db.prepare("SELECT status FROM jobs_queue").get()?.status).toBe("succeeded");
  });
  it("deduplicates updates under a stable UUIDv7 and retains newer work", async () => {
    const { queue } = await fixture();
    const payload = testJobPayload("image");
    const inserted = (await queue.enqueue("image:test", "image", "a", "file:test", payload))!;
    expect(inserted.id).toMatch(/^[0-9a-f-]{14}7[0-9a-f-]{21}$/);
    const job = (await queue.claim(["image"]))!;
    const updated = (await queue.enqueue("image:test", "image", "a", "file:test", { ...payload, mode: "replace" }, new Date(), true))!;
    expect(updated.id).toBe(inserted.id);
    expect(updated.lease).toBe(job.lease);
    expect(await queue.claim(["image"])).toBeNull();
    await queue.complete(job);
    const retry = (await queue.claim(["image"]))!;
    expect(retry.generation).toBe(job.generation + 1);
    expect(retry.payload.mode).toBe("replace");
    await queue.complete(retry);
    expect(await queue.claim(["image"])).toBeNull();
  });
  it("keeps cancelled leases in capacity and target exclusion until settlement", async () => {
    const { queue, sqlDb, db } = await fixture();
    await queue.enqueue("image:cancel", "image", "a", "same", testJobPayload("image"));
    const claim = (await queue.claim(["image"]))!;
    await sqlDb.transaction((tx) => cancelJobs(tx, schema, eq(schema.backgroundJob.id, claim.id)));
    expect(db.prepare("SELECT status,lease FROM jobs_queue WHERE id = ?").get(claim.id))
      .toMatchObject({ status: "cancelled", lease: claim.lease });
    expect(await sqlDb.transaction((tx) => lockJob(tx, schema, claim))).toBeUndefined();
    await queue.enqueue("image:other", "image", "b", "other", testJobPayload("image"));
    await queue.enqueue("summary:same", "summary", "b", "same", testJobPayload("summary"));
    expect(await queue.claim(["image", "summary"])).toBeNull();
    await queue.complete(claim);
    expect(await queue.claim(["image", "summary"])).not.toBeNull();
  });
  it("blocks an immediate summary retry behind the cancelled execution and rejects cross-method duplicates", async () => {
    const { queue, sqlDb } = await fixture();
    await queue.enqueue("summary:first", "summary", "a", "meeting", testJobPayload("summary"));
    await expect(queue.enqueue("summary:duplicate", "audio-summary", "b", "meeting", testJobPayload("audio-summary"))).rejects.toThrow();
    const claim = (await queue.claim(["summary"]))!;
    await sqlDb.transaction((tx) => cancelJobs(tx, schema, eq(schema.backgroundJob.id, claim.id), true));
    await queue.enqueue("summary:retry", "audio-summary", "a", "meeting", testJobPayload("audio-summary"));
    expect(await queue.claim(["summary", "audio-summary"])).toBeNull();
    await queue.complete(claim);
    expect((await queue.claim(["summary", "audio-summary"]))?.dedupeKey).toBe("summary:retry");
  });
  it("refuses expired publication and rolls registration back with canonical writes", async () => {
    const { queue, sqlDb, db } = await fixture();
    await expect(sqlDb.transaction(async (tx) => {
      await tx.insert(schema.user).values({ id: "rollback", name: "Owner", email: "rollback@example.com", updatedAt: new Date() });
      await enqueueJob(tx, schema, "image:rollback", "image", "a", "rollback", testJobPayload("image"));
      throw new Error("rollback");
    })).rejects.toThrow("rollback");
    expect(db.prepare("SELECT id FROM user WHERE id = 'rollback'").all()).toEqual([]);
    expect(db.prepare("SELECT id FROM jobs_queue").all()).toEqual([]);
    await queue.enqueue("image:expired", "image", "a", "expired", testJobPayload("image"));
    const claim = (await queue.claim(["image"]))!;
    db.exec("UPDATE jobs_queue SET lease_until = 0");
    expect(await sqlDb.transaction((tx) => lockJob(tx, schema, claim))).toBeUndefined();
    await queue.complete(claim);
    const recovered = (await queue.claim(["image"]))!;
    expect(recovered.id).toBe(claim.id);
    expect(recovered.lease).not.toBe(claim.lease);
  });
  it("rejects malformed payloads before durable registration", async () => {
    const { queue } = await fixture();
    await expect(queue.enqueue("image:invalid", "image", "a", "file", {})).rejects.toThrow();
    await expect(queue.enqueue("reconcile:invalid", "reconcile", "a", "scope", { kind: "image", phase: "page" })).rejects.toThrow();
    await expect(queue.enqueue("chat:invalid", "chat-memory", "a", "chat", { ...testJobPayload("chat-memory"), memoryKind: "working" })).rejects.toThrow();
    expect(await queue.claim(["image"])).toBeNull();
  });
  it("orders search batches by availability, bounds them at sixteen and uses one execution slot", async () => {
    const { queue, db } = await fixture();
    for (let i = 0; i < 17; i++) await queue.enqueue(`doc${i}`, "search", "scope", `doc${i}`, testJobPayload("search"));
    db.exec("UPDATE jobs_queue SET created_at = CASE WHEN dedupe_key = 'doc16' THEN 2000 ELSE 1000 END, available_at = CASE WHEN dedupe_key = 'doc16' THEN 0 ELSE 1000 END");
    const job = (await queue.claim(["search"]))!;
    expect(job.dedupeKey).toBe("doc16");
    expect(job.batch[0]?.dedupeKey).toBe("doc16");
    expect(job.batch).toHaveLength(16);
    expect(await queue.claim(["search"])).toBeNull();
    for (const item of job.batch) await queue.complete(item);
    expect((await queue.claim(["search"]))!.batch).toHaveLength(1);
  });
  it("waits past each five-minute lease before infrastructure retries reach the DLQ", async () => {
    const { queue } = await fixture();
    vi.useFakeTimers();
    await queue.enqueue("memory", "workspace-memory", "owner", "memory", testJobPayload("workspace-memory"));
    const first = (await queue.claim(["workspace-memory"]))!;
    await queue.retry(first);
    vi.setSystemTime(Date.now() + 6_000);
    expect(await queue.claim(["workspace-memory"])).toBeNull();
    vi.setSystemTime(first.leaseUntil.getTime() + 1_000);
    const second = (await queue.claim(["workspace-memory"]))!;
    expect(second.dispatchAttempts).toBe(2);
    await queue.retry(second);
    vi.setSystemTime(second.leaseUntil.getTime() + 1_000);
    const third = (await queue.claim(["workspace-memory"]))!;
    expect(third.dispatchAttempts).toBe(3);
    await queue.retry(third);
    expect(await queue.nextDelay(["workspace-memory"])).toBeUndefined();
  });
  it("shares throttling across kinds using the same summary budget", async () => {
    const { queue } = await fixture();
    await queue.enqueue("text", "summary", "a", "one", testJobPayload("summary"));
    await queue.enqueue("audio", "audio-summary", "a", "two", testJobPayload("audio-summary"));
    await queue.cooldown("audio-summary", Date.now() + 30_000);
    expect(await queue.claim(["summary", "audio-summary"])).toBeNull();
  });
  it("claims through separate OS processes without duplicate delivery", async () => {
    const { queue, url } = await fixture();
    await queue.enqueue("shared", "image", "a", "shared", testJobPayload("image"));
    const claims = await Promise.all(Array.from({ length: 3 }, () => new Promise<unknown>((resolve, reject) => {
      const child = fork(new URL("./fixtures/job-claim.ts", import.meta.url), [url], { execArgv: ["--import", "tsx"], stdio: ["ignore", "ignore", "pipe", "ipc"] });
      let result: unknown;
      child.once("message", (message) => { result = message; });
      child.once("error", reject);
      child.once("exit", (code) => { if (code === 0) resolve(result); else reject(new Error(`child exit ${code}`)); });
    })));
    expect(claims.filter(Boolean)).toHaveLength(1);
    // Include three Node/tsx startups and SQLite's 5s busy wait on shared CI runners.
  }, 30_000);
});
describe("resource configuration", () => {
  it("divides the memory budget across workers instead of multiplying independent CPU heuristics", () => {
    const auto = loadJobConfig({});
    expect(jobResources(auto, 8, 16 * 1024 ** 3)).toMatchObject({ workers: 6, concurrency: 4, slots: 24 });
    expect(jobResources(auto, 2, 8 * 1024 ** 3)).toMatchObject({ workers: 2, concurrency: 6, slots: 12 });
    expect(jobResources(auto, 1, 512 * 1024 ** 2)).toMatchObject({ workers: 1, concurrency: 1 });
    expect(jobResources({ ...auto, workers: 2 }, 8, 16 * 1024 ** 3)).toMatchObject({ workers: 2, concurrency: 8 });
    expect(jobResources({ ...auto, concurrency: 8 }, 8, 16 * 1024 ** 3)).toMatchObject({ workers: 3, concurrency: 8 });
  });
  it("validates overrides", () => {
    expect(loadJobConfig({ DAHLIA_JOB_WORKERS: "2", DAHLIA_JOB_CONCURRENCY: "8", DAHLIA_JOB_LIMITS: '{"summary":16}' }))
      .toMatchObject({ workers: 2, concurrency: 8, limits: { summary: 16 } });
    for (const env of [{ DAHLIA_JOB_WORKERS: "0" }, { DAHLIA_JOB_CONCURRENCY: "9" }, { DAHLIA_JOB_LIMITS: '{"unknown":1}' }]) expect(() => loadJobConfig(env)).toThrow();
  });
  it("bounds async execution and drains admitted work on shutdown", async () => {
    let active = 0, maximum = 0, started!: () => void, finish!: () => void;
    const ready = new Promise<void>((resolve) => { started = resolve; });
    const released = new Promise<void>((resolve) => { finish = resolve; });
    const runner = new JobRunner({ processOne: async (signal) => {
      if (signal.aborted) return false;
      maximum = Math.max(maximum, ++active);
      if (active === 4) started();
      await released; active--; return true;
    } }, 4);
    runner.start(); await ready;
    const stopped = runner.stop(); finish(); await stopped;
    expect(maximum).toBe(4); expect(active).toBe(0);
  });
});
