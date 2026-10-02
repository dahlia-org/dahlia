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
  return { queue: store.jobs, db, url };
}
describe("shared durable dispatch", () => {
  it("lets waiting memory run ahead of an older image after its retry becomes due", async () => {
    const { queue, db } = await fixture();
    await queue.enqueue("image", "image", "owner", "file", {});
    await queue.enqueue("memory", "workspace-memory", "owner", "memory", {});
    db.exec("UPDATE jobs_queue SET created_at = CASE WHEN id = 'image' THEN 1000 ELSE 2000 END, available_at = 0");
    const image = (await queue.claim(["image", "workspace-memory"]))!;
    expect(image.id).toBe("image");
    await queue.reschedule(image, image.reference, 0);
    expect((await queue.claim(["image", "workspace-memory"]))!.id).toBe("memory");
  });
  it("runs memory before rechecking an older image whose source is not ready", async () => {
    const { queue, db } = await fixture();
    vi.useFakeTimers();
    await queue.enqueue("image", "image", "owner", "file", { fileId: "file", ownerUserId: "owner", model: "model" });
    await queue.enqueue("memory", "workspace-memory", "owner", "memory", { scopeId: "scope" });
    db.exec("UPDATE jobs_queue SET created_at = CASE WHEN id = 'image' THEN 1000 ELSE 2000 END");
    const claim = vi.fn().mockResolvedValue(null), step = vi.fn().mockResolvedValue(undefined);
    const executor = createJobExecutor({ queue: { ...queue, sourceAvailableAt: async () => new Date(0) },
      summaryJobs: {} as never, methods: [], sync: {} as never, syncStore: {} as never,
      imageAnalysis: { claim } as never, captioner: { model: "model" } as never, memory: { step } as never });
    const signal = new AbortController().signal;
    await executor.processOne(signal);
    expect(claim).toHaveBeenCalledOnce();
    vi.setSystemTime(Date.now() + 2_000);
    await executor.processOne(signal);
    expect(step).toHaveBeenCalledWith("scope", expect.any(AbortSignal));
    expect(claim).toHaveBeenCalledOnce();
    expect(await executor.processOne(signal)).toBe(false);
    vi.setSystemTime(Date.now() + 60_000);
    await executor.processOne(signal);
    expect(claim).toHaveBeenCalledTimes(2);
    vi.setSystemTime(Date.now() + 60_000);
    await executor.processOne(signal);
    expect(db.prepare("SELECT status, attempts, last_error FROM jobs_queue WHERE id = 'image'").get())
      .toMatchObject({ status: "failed", attempts: 3, last_error: "job_source_not_ready" });
    vi.setSystemTime(Date.now() + 60_000);
    expect(await executor.processOne(signal)).toBe(false);
    expect(claim).toHaveBeenCalledTimes(3);
    await queue.enqueue("image", "image", "owner", "file", { fileId: "file", ownerUserId: "owner", model: "model" });
    await executor.processOne(signal);
    expect(claim).toHaveBeenCalledTimes(4);
    expect(db.prepare("SELECT status, attempts FROM jobs_queue WHERE id = 'image'").get())
      .toMatchObject({ status: "pending", attempts: 1 });
  });
  it("revives failed recurring work without replacing pending or active registrations", async () => {
    const { queue, db } = await fixture();
    for (const [id, kind] of [["maintenance", "maintenance"], ["reconcile:image:scope", "reconcile"]] as const) {
      await queue.enqueue(id, kind, "", id, { after: "old" });
      db.prepare("UPDATE jobs_queue SET attempts = 2 WHERE id = ?").run(id);
      const failed = (await queue.claim([kind]))!;
      await queue.retry(failed);
      expect(db.prepare("SELECT status FROM jobs_queue WHERE id = ?").get(id)?.status).toBe("failed");
      await queue.enqueue(id, kind, "", id, { after: "new" });
      await queue.enqueue(id, kind, "", id, { after: "ignored-pending" });
      const revived = (await queue.claim([kind]))!;
      expect(revived).toMatchObject({ attempts: 1, reference: { after: "new" } });
      await queue.enqueue(id, kind, "", id, { after: "ignored-active" });
      expect(await queue.claim([kind])).toBeNull();
      await queue.complete(revived);
    }
  });
  it("retains source-backed dispatch in the DLQ after three infrastructure failures and revives on registration", async () => {
    const { queue, db } = await fixture();
    for (const kind of jobKinds.filter((kind) => kind !== "maintenance" && kind !== "reconcile")) {
      await queue.enqueue(kind, kind, "owner", kind, {});
      db.prepare("UPDATE jobs_queue SET attempts = 2 WHERE id = ?").run(kind);
      await queue.retry((await queue.claim([kind]))!);
      expect(db.prepare("SELECT status, attempts FROM jobs_queue WHERE id = ?").get(kind)).toMatchObject({ status: "failed", attempts: 3 });
      expect(await queue.claim([kind])).toBeNull();
      expect(await queue.nextDelay([kind])).toBeUndefined();
      await queue.enqueue(kind, kind, "owner", kind, {});
      const recovered = (await queue.claim([kind]))!;
      expect(recovered.attempts).toBe(1);
      await queue.complete(recovered);
    }
  });
  it("enforces caps, target serialization, owner fairness and old-first eligibility", async () => {
    const { queue } = await fixture();
    for (const [id, kind, owner, target] of [
      ["a1", "image", "a", "file1"], ["a2", "image", "a", "file2"], ["b1", "summary", "b", "meeting1"],
      ["b2", "summary", "b", "meeting1"], ["b3", "summary", "b", "meeting2"],
    ] as const) await queue.enqueue(id, kind, owner, target, {});
    const first = (await queue.claim(["image", "summary"]))!;
    expect(first.id).toBe("a1");
    const second = (await queue.claim(["image", "summary"]))!;
    expect(second.id).toBe("b1");
    expect((await queue.claim(["image", "summary"]))!.id).toBe("b3");
    expect(await queue.claim(["image", "summary"])).toBeNull();
    await queue.complete(first);
    expect((await queue.claim(["image", "summary"]))!.id).toBe("a2");
    await queue.complete(second);
    expect((await queue.claim(["image", "summary"]))!.id).toBe("b2");
  });
  it("preserves newer work and rejects completion from an expired lease", async () => {
    const { queue, db } = await fixture();
    await queue.enqueue("one", "summary", "a", "meeting", {});
    const first = (await queue.claim(["summary"]))!;
    db.exec("UPDATE jobs_queue SET generation = generation + 1");
    await queue.complete(first);
    const next = (await queue.claim(["summary"]))!;
    expect(next.generation).toBe(2);
    expect(next.attempts).toBe(1);
    db.exec("UPDATE jobs_queue SET lease_until = 0");
    const retry = (await queue.claim(["summary"]))!;
    expect(retry.lease).not.toBe(next.lease);
    await queue.complete(next);
    expect(await queue.claim(["summary"])).toBeNull();
    await queue.complete(retry);
    expect(db.prepare("SELECT count(*) AS n FROM jobs_queue").get()?.n).toBe(0);
  });
  it("atomically registers domain retries while retaining the active dispatch lease", async () => {
    const { queue, db } = await fixture();
    db.exec("INSERT INTO jobs_storage_delete(storage_key) VALUES ('synthetic')");
    const job = (await queue.claim(["storage-delete"]))!;
    expect(job.reference).toEqual({ storageKey: "synthetic" });
    db.exec("UPDATE jobs_storage_delete SET status = 'failed', available_at = 100");
    expect(await queue.claim(["storage-delete"])).toBeNull();
    await queue.complete(job);
    const retry = (await queue.claim(["storage-delete"]))!;
    expect(retry.generation).toBeGreaterThan(job.generation);
    expect(retry.attempts).toBe(1);
    db.exec("DELETE FROM jobs_storage_delete");
    await queue.complete(retry);
    expect(await queue.claim(["storage-delete"])).toBeNull();
    db.exec("BEGIN; INSERT INTO jobs_storage_delete(storage_key) VALUES ('rolled-back'); ROLLBACK;");
    expect(await queue.claim(["storage-delete"])).toBeNull();
  });
  it("counts a search batch as one execution slot and bounds it at sixteen documents", async () => {
    const { queue } = await fixture();
    for (let i = 0; i < 17; i++) await queue.enqueue(`doc${i}`, "search", "scope", `doc${i}`, {});
    const job = (await queue.claim(["search"]))!;
    expect(job.batch).toHaveLength(16);
    expect(await queue.claim(["search"])).toBeNull();
    for (const item of job.batch) await queue.complete(item);
    expect((await queue.claim(["search"]))!.batch).toHaveLength(1);
  });
  it("shares throttling across kinds using the same summary budget", async () => {
    const { queue } = await fixture();
    await queue.enqueue("text", "summary", "a", "one", {});
    await queue.enqueue("audio", "audio-summary", "a", "two", {});
    await queue.cooldown("audio-summary", Date.now() + 30_000);
    expect(await queue.claim(["summary", "audio-summary"])).toBeNull();
  });
  it("claims through separate OS processes without duplicate delivery", async () => {
    const { queue, url } = await fixture();
    await queue.enqueue("shared", "image", "a", "shared", {});
    const claims = await Promise.all(Array.from({ length: 3 }, () => new Promise<unknown>((resolve, reject) => {
      const child = fork(new URL("./fixtures/job-claim.ts", import.meta.url), [url], { execArgv: ["--import", "tsx"], stdio: ["ignore", "ignore", "pipe", "ipc"] });
      let result: unknown;
      child.once("message", (message) => { result = message; });
      child.once("error", reject);
      child.once("exit", (code) => { if (code === 0) resolve(result); else reject(new Error(`child exit ${code}`)); });
    })));
    expect(claims.filter(Boolean)).toEqual(["shared"]);
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
