import { afterAll, describe, expect, it } from "vitest";
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
    await connection.db.execute(sql`delete from jobs.queue where id like ${prefix + "%"}`);
    await connection.close();
  });
  it("lets waiting memory precede deferred source work and retains exhausted work in the DLQ", async () => {
    const sourceId = `${prefix}:source`, memoryId = `${prefix}:memory`;
    await jobs!.enqueue(sourceId, "summary", prefix, sourceId, {}, new Date(0));
    await jobs!.enqueue(memoryId, "workspace-memory", prefix, memoryId, {}, new Date(0));
    await connection!.db.execute(sql`update jobs.queue set created_at = case when id = ${sourceId} then timestamp '2000-01-01' else timestamp '2000-01-02' end where id in (${sourceId}, ${memoryId})`);
    const source = (await jobs!.claim(["summary", "workspace-memory"]))!;
    expect(source.id).toBe(sourceId);
    await jobs!.retry(source, { delayMs: 0, errorCode: "job_source_not_ready" });
    const memory = (await jobs!.claim(["summary", "workspace-memory"]))!;
    expect(memory.id).toBe(memoryId);
    await jobs!.complete(memory);
    await connection!.db.execute(sql`update jobs.queue set attempts = 2 where id = ${sourceId}`);
    await jobs!.retry((await jobs!.claim(["summary"]))!, { delayMs: 0, errorCode: "job_source_not_ready" });
    expect((await connection!.db.execute(sql`select status, attempts, last_error from jobs.queue where id = ${sourceId}`)).rows)
      .toEqual([{ status: "failed", attempts: 3, last_error: "job_source_not_ready" }]);
    expect(await jobs!.claim(["summary", "workspace-memory"])).toBeNull();
  });
  it("uses a non-superuser without bypass and atomically enforces caps across pooled connections", async () => {
    const role = await connection!.db.execute<{ rolsuper: boolean; rolbypassrls: boolean }>(sql`select rolsuper, rolbypassrls from pg_roles where rolname = current_user`);
    expect(role.rows[0]).toEqual({ rolsuper: false, rolbypassrls: false });
    for (let i = 0; i < 4; i++) await jobs!.enqueue(`${prefix}:${i}`, "image", prefix, `${prefix}:${i}`, {});
    const claims = await Promise.all(Array.from({ length: 8 }, () => jobs!.claim(["image"])));
    expect(claims.filter(Boolean)).toHaveLength(1);
    await jobs!.complete(claims.find((claim) => claim)!);
    expect(await jobs!.claim(["image"])).not.toBeNull();
  });
  it("registers canonical deletion and removes dispatch with its source", async () => {
    await connection!.db.transaction(async (tx) => {
      await tx.execute(sql`insert into jobs.storage_delete(storage_key) values (${prefix})`);
      const rows = await tx.execute(sql`select id from jobs.queue where id = ${"storage-delete:" + prefix}`);
      expect(rows.rows).toHaveLength(1);
    });
    await connection!.db.execute(sql`delete from jobs.storage_delete where storage_key = ${prefix}`);
    expect((await connection!.db.execute(sql`select id from jobs.queue where id = ${"storage-delete:" + prefix}`)).rows).toHaveLength(0);
  });
});
