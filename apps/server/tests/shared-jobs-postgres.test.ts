import { testJobPayload } from "./fixtures/job-payload";
import { enqueueStorageDelete, cancelJobs, lockJob } from "../src/jobs/state";
import * as schema from "../src/db/auth-schema";
import { eq, inArray } from "drizzle-orm";
import { afterAll, describe, expect, it, vi } from "vitest";
import { drizzle } from "drizzle-orm/node-postgres";
import { sql } from "drizzle-orm";
import { connectPostgresUrl } from "../src/db/postgres";
import { createJobStore } from "../src/jobs/store";
import { defaultJobLimits } from "../src/jobs/model";
import { uuidV7 } from "../src/id";
// Use an isolated migrated DB: these assertions require no unrelated dispatchers.
const url = process.env.TEST_JOB_DATABASE_URL;
describe.runIf(url)("PostgreSQL shared job dispatch without RLS bypass", () => {
  const connection = url ? connectPostgresUrl(url, 8) : undefined;
  const jobs = connection && createJobStore(connection.db, true, { ...defaultJobLimits, image: 1 });
  const prefix = uuidV7();
  afterAll(async () => {
    if (!connection) return;
    await connection.db.execute(sql`delete from jobs.queue where dedupe_key like ${prefix + "%"}`);
    await connection.close();
  });
  it("lets waiting memory precede deferred source work and retains exhausted work in the DLQ", async () => {
    const sourceId = `${prefix}:source`, memoryId = `${prefix}:memory`;
    await jobs!.enqueue(sourceId, "summary", prefix, sourceId, testJobPayload("summary"), new Date(0));
    await jobs!.enqueue(memoryId, "workspace-memory", prefix, memoryId, testJobPayload("workspace-memory"), new Date(0));
    await connection!.db.execute(sql`update jobs.queue set created_at = case when dedupe_key = ${sourceId} then timestamp '2000-01-01' else timestamp '2000-01-02' end where dedupe_key in (${sourceId}, ${memoryId})`);
    const source = (await jobs!.claim(["summary", "workspace-memory"]))!;
    expect(source.dedupeKey).toBe(sourceId);
    await jobs!.retry(source, { delayMs: 0, errorCode: "job_source_not_ready" });
    const memory = (await jobs!.claim(["summary", "workspace-memory"]))!;
    expect(memory.dedupeKey).toBe(memoryId);
    await jobs!.complete(memory);
    await connection!.db.execute(sql`update jobs.queue set dispatch_attempts = 2, available_at = timestamp '2000-01-01' where dedupe_key = ${sourceId}`);
    await jobs!.retry((await jobs!.claim(["summary"]))!, { delayMs: 0, errorCode: "job_source_not_ready" });
    expect((await connection!.db.execute(sql`select status, attempts, dispatch_attempts, last_error from jobs.queue where dedupe_key = ${sourceId}`)).rows)
      .toEqual([{ status: "failed", attempts: 0, dispatch_attempts: 3, last_error: "job_source_not_ready" }]);
    expect(await jobs!.claim(["summary", "workspace-memory"])).toBeNull();
  });
  it.each([
    ["summary", "cancel"], ["search", "cancel"], ["image", "replace"], ["image", "repair"],
  ] as const)("preserves a concurrent %s %s between selection and lease writes", async (kind, action) => {
    const key = `${prefix}:${kind}:${action}`, sibling = `${key}:sibling`;
    const keys = kind === "search" ? [key, sibling] : [key];
    const payload = testJobPayload(kind);
    for (const id of keys) await jobs!.enqueue(id, kind, prefix, id, payload);
    if (action === "repair") await connection!.db.update(schema.backgroundJob).set({ payload: { fileId: "invalid" } })
      .where(eq(schema.backgroundJob.dedupeKey, key));

    const client = await connection!.pool.connect();
    const { rows: [backend] } = await client.query<{ pid: number }>("SELECT pg_backend_pid() AS pid");
    let notifySelected!: () => void, resume!: () => void;
    const selected = new Promise<void>((resolve) => { notifySelected = resolve; });
    const resumed = new Promise<void>((resolve) => { resume = resolve; });
    const original = client.query.bind(client);
    let selections = 0;
    client.query = new Proxy(original, {
      async apply(query, receiver, args) {
        const result: unknown = await (Reflect.apply(query, receiver, args) as Promise<unknown>);
        const input: unknown = args[0];
        const text = typeof input === "string" ? input : (input as { text: string }).text;
        if (text.startsWith("select ") && text.includes('from "jobs"."queue"') && text.includes("limit")) {
          selections++;
          if (selections === (kind === "search" ? 2 : 1)) {
            notifySelected();
            await resumed;
          }
        }
        return result;
      },
    });
    const queue = createJobStore(drizzle({ client }), true, defaultJobLimits);
    const claiming = queue.claim([kind], keys);
    let mutation: Promise<unknown> | undefined;
    const changed = kind === "search" ? sibling : key;
    try {
      await Promise.race([selected, claiming.then(() => { throw new Error("claim finished before candidate interception"); })]);
      let written = false;
      mutation = (action === "cancel"
        ? cancelJobs(connection!.db, schema, eq(schema.backgroundJob.dedupeKey, changed), true)
        : jobs!.enqueue(key, kind, prefix, key, { ...payload, mode: "replace" }, new Date(), true))
        .finally(() => { written = true; });
      // Observe the concurrent writer reaching the row; do not depend on a fixed sleep.
      await vi.waitFor(async () => {
        const waiting = await connection!.pool.query<{ blocked: boolean }>(
          "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))) AS blocked", [backend!.pid]);
        expect(written || waiting.rows[0]?.blocked).toBe(true);
      });
      resume();
      const [claim] = await Promise.all([claiming, mutation]);
      const [current] = await connection!.db.select().from(schema.backgroundJob).where(eq(schema.backgroundJob.dedupeKey, changed));
      if (action === "cancel") {
        const cancelled = claim!.batch.find((job) => job.dedupeKey === changed)!;
        expect(current).toMatchObject({ status: "cancelled", lease: cancelled.lease, generation: cancelled.generation + 1 });
        expect(await connection!.db.transaction((tx) => lockJob(tx, schema, cancelled))).toBeUndefined();
      } else {
        expect(current).toMatchObject({ status: action === "repair" ? "pending" : "processing", payload: { mode: "replace" }, generation: 2 });
        if (claim) expect(await connection!.db.transaction((tx) => lockJob(tx, schema, claim))).toBeUndefined();
      }
      for (const job of claim?.batch ?? []) await queue.complete(job);
      const next = await queue.claim([kind], keys);
      if (action === "cancel") expect(next).toBeNull();
      else {
        expect(next).toMatchObject({ generation: 2, payload: { mode: "replace" } });
        await queue.complete(next!);
      }
    } finally {
      resume();
      await Promise.allSettled([claiming, ...(mutation ? [mutation] : [])]);
      client.query = original;
      client.release();
      await connection!.db.delete(schema.backgroundJob).where(inArray(schema.backgroundJob.dedupeKey, keys));
    }
  });
  it("uses a non-superuser without bypass and atomically enforces caps across pooled connections", async () => {
    const role = await connection!.db.execute<{ rolsuper: boolean; rolbypassrls: boolean }>(sql`select rolsuper, rolbypassrls from pg_roles where rolname = current_user`);
    expect(role.rows[0]).toEqual({ rolsuper: false, rolbypassrls: false });
    for (let i = 0; i < 4; i++) await jobs!.enqueue(`${prefix}:${i}`, "image", prefix, `${prefix}:${i}`, testJobPayload("image"));
    const claims = await Promise.all(Array.from({ length: 8 }, () => jobs!.claim(["image"])));
    expect(claims.filter(Boolean)).toHaveLength(1);
    await jobs!.complete(claims.find((claim) => claim)!);
    expect(await jobs!.claim(["image"])).not.toBeNull();
  });
  it.each([
    ["summary", "complete"], ["summary", "expire"], ["audio-summary", "complete"], ["audio-summary", "expire"],
  ] as const)("releases a purged %s cancellation after lease %s", async (kind, finish) => {
      const key = `${prefix}:purge:${kind}:${finish}`;
      await jobs!.enqueue(key, kind, prefix, key, testJobPayload(kind));
      const claim = (await jobs!.claim([kind], [key]))!;
      await cancelJobs(connection!.db, schema, eq(schema.backgroundJob.id, claim.id), true);
      expect((await connection!.db.select().from(schema.backgroundJob).where(eq(schema.backgroundJob.id, claim.id)))[0])
        .toMatchObject({ status: "cancelled", retainCancelled: true, lease: claim.lease });
      await cancelJobs(connection!.db, schema, eq(schema.backgroundJob.id, claim.id));
      expect((await connection!.db.select().from(schema.backgroundJob).where(eq(schema.backgroundJob.id, claim.id)))[0])
        .toMatchObject({ status: "cancelled", retainCancelled: false, lease: claim.lease });
      if (finish === "complete") await jobs!.complete(claim);
      else {
        await connection!.db.update(schema.backgroundJob).set({ leaseUntil: new Date(0) }).where(eq(schema.backgroundJob.id, claim.id));
        expect(await jobs!.claim([kind], [key])).toBeNull();
      }
      expect(await connection!.db.select().from(schema.backgroundJob).where(eq(schema.backgroundJob.id, claim.id))).toEqual([]);
    });
  it("registers canonical deletion and removes dispatch with its source", async () => {
    await connection!.db.transaction(async (tx) => {
      await enqueueStorageDelete(tx, schema, prefix);
      const rows = await tx.execute(sql`select id from jobs.queue where dedupe_key = ${"storage-delete:" + prefix}`);
      expect(rows.rows).toHaveLength(1);
    });
    await cancelJobs(connection!.db, schema, eq(schema.backgroundJob.dedupeKey, `storage-delete:${prefix}`));
    expect((await connection!.db.execute(sql`select id from jobs.queue where dedupe_key = ${"storage-delete:" + prefix}`)).rows).toHaveLength(0);
  });
});
