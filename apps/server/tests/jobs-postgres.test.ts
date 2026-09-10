import { summaryStyleDetail } from "../src/account-settings-model";
import { describe, expect, it } from "vitest";
import { sql } from "drizzle-orm";
import { connectPostgresUrl } from "../src/db/postgres";
import { createPostgresApplicationStore } from "../src/auth/store";
import { createSummaryJobStore } from "../src/summary/store";
import { SummaryService } from "../src/summary/service";
import { processSummaryJob } from "../src/summary/process";
import { summaryDocument, type SummaryMethod } from "../src/summary/model";
import { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "../src/id";
const databaseUrl = process.env.TEST_DATABASE_URL;
describe.runIf(databaseUrl)("PostgreSQL targeted summary delivery", () => {
  it.each(["duplicate", "retry", "lease", "cancel", "permission", "conflict"])("protects durable results across %s delivery", async (scenario) => {
    const connection = connectPostgresUrl(databaseUrl!, 5);
    const store = createPostgresApplicationStore(connection.db, "postgres");
    const jobs = createSummaryJobStore(connection.db, true);
    const userId = uuidV7(); const identity = { userId, workspaceId: `personal:${userId}`, source: "header" as const };
    const sync = new MeetingSyncService(store.sync);
    const vaultId = uuidV7(), meetingId = uuidV7(); const now = new Date().toISOString();
    const document = summaryDocument({ title: "Synthetic", description: "test", tags: [], action_items: [], sections: [{ heading: "Test", blocks: [{ type: "paragraph", level: 3, content: { text: "Synthetic", transcript_ref: null }, items: [], language: "", image_id: "" }] }] }, new Set());
    let generations = 0;
    const method: SummaryMethod = { id: "transcript", captureSettings: (settings) => ({
      model: (settings.processing.remote.summaryModel ?? "gemini-3-8-flash"), reasoningEffort: (settings.processing.remote.reasoningEffort ?? "medium"),
      detail: summaryStyleDetail(settings.summary.style),
    }),
      version: () => Promise.resolve("v1"), generate: async () => {
        generations++;
        if (scenario === "permission") await connection.db.execute(sql`delete from app.vault_permissions where vault_id = ${vaultId}`);
        if (scenario === "conflict") await connection.db.transaction(async (tx) => {
          await tx.execute(sql`select set_config('app.user_id', ${userId}, true)`);
          await tx.execute(sql`update app.meetings set summary_revision = summary_revision + 1 where meeting_id = ${meetingId}`);
        });
        return document;
      } };
    const service = new SummaryService(store.sync, store.accountSettings, [method]);
    try {
      await store.ensureIdentityUser(identity);
      await sync.commitTransaction(identity, { schemaVersion: 2, id: uuidV7(), vaultId, createdAt: now, operations: [
        { id: uuidV7(), entity: "vault", action: "create", entityId: vaultId, baseRevision: null, data: { name: "Synthetic", createdAt: now } },
        { id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
          data: { name: "Test", description: "", status: "READY", projectId: null, duration: 0, recordingStartedAt: null, createdAt: now, updatedAt: now } },
      ] });
      const accepted = await service.start(identity, vaultId, meetingId, { id: uuidV7() });
      const reference = { id: accepted.id, ownerUserId: userId };
      expect(await jobs.claim({ ...reference, ownerUserId: uuidV7() })).toBeNull();
      expect(await jobs.due(userId)).toContainEqual(reference);
      if (scenario === "cancel") {
        await service.cancel(identity, vaultId, meetingId, accepted.id);
        expect(await processSummaryJob(jobs, [method], sync, new AbortController().signal, reference)).toBe(false);
        expect(generations).toBe(0); return;
      }
      if (scenario === "retry") {
        const claimed = (await jobs.claim(reference))!;
        await jobs.fail(claimed, "temporary", true);
        expect(await jobs.claim(reference)).toBeNull();
        await connection.db.transaction(async (tx) => {
          await tx.execute(sql`select set_config('app.user_id', ${userId}, true)`);
          await tx.execute(sql`update jobs.summary set available_at = timestamp '1970-01-01' where id = ${accepted.id}`);
        });
      }
      if (scenario === "lease") {
        const claims = await Promise.all([jobs.claim(reference), jobs.claim(reference)]);
        expect(claims.filter(Boolean)).toHaveLength(1);
        await connection.db.transaction(async (tx) => {
          await tx.execute(sql`select set_config('app.user_id', ${userId}, true)`);
          await tx.execute(sql`update jobs.summary set lease_expires_at = timestamp '1970-01-01' where id = ${accepted.id}`);
        });
        expect(await jobs.due(userId)).toContainEqual(reference);
      }
      await Promise.all([processSummaryJob(jobs, [method], sync, new AbortController().signal, reference),
        processSummaryJob(jobs, [method], sync, new AbortController().signal, reference)]);
      expect(generations).toBe(1);
      expect(await jobs.claim(reference)).toBeNull();
      if (scenario !== "permission") {
        const status = await service.status(identity, vaultId, meetingId);
        expect(status?.status).toBe(scenario === "conflict" ? "failed" : "succeeded");
        expect(status?.attempts).toBe(["lease", "retry"].includes(scenario) ? 2 : 1);
        const versions = await store.sync.withIdentity(identity, (scoped) => scoped.listSummaryVersions(vaultId, meetingId, 100));
        expect(versions).toHaveLength(scenario === "conflict" ? 0 : 1);
      }
    } finally { await connection.close(); }
  });
});
