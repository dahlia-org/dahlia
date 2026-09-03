import { afterAll, describe, expect, it } from "vitest";
import { eq, sql } from "drizzle-orm";

import { createPostgresAuthStore } from "../src/auth/store";
import type { Identity } from "../src/auth/identity";
import type { AppConfig } from "../src/config";
import { connectAuthDatabase } from "../src/db/client";
import * as schema from "../src/db/auth-schema";
import { SyncTransactionError } from "../src/sync/store";
import type { IdentitySyncStore, SyncTransactionOperation } from "../src/sync/types";

const databaseUrl = process.env.TEST_DATABASE_URL;
const integration = describe.runIf(databaseUrl);
const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "postgres",
  databaseUrl,
  baseUrl: "https://dahlia.example",
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
};
const connection = databaseUrl ? connectAuthDatabase(config) : undefined;

afterAll(async () => connection?.close());

integration("PostgreSQL application store", () => {
  it("serializes optimistic transactions within a Vault", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres", undefined, true);
    const userId = crypto.randomUUID();
    const identity: Identity = { userId, workspaceId: `personal:${userId}`, source: "header" };
    const vaultId = crypto.randomUUID();
    expect(await store.ensureIdentityUser(identity)).toBe(true);
    await store.sync.withIdentity(identity, (sync) => createVault(sync, vaultId));
    const update = (name: string) => store.sync.withIdentity(identity, (sync) => sync.commitTransaction({
      schemaVersion: 1,
      id: crypto.randomUUID(),
      vaultId,
      createdAt: new Date(),
      requestHash: name,
      operations: [{
        id: crypto.randomUUID(),
        entity: "vault",
        action: "update",
        entityId: vaultId,
        baseRevision: 1,
        data: { name },
      }],
    }));

    const results = await Promise.allSettled([update("First"), update("Second")]);
    expect(results.filter(({ status }) => status === "fulfilled")).toHaveLength(1);
    const rejected = results.find((result) => result.status === "rejected");
    if (rejected?.status !== "rejected") throw new Error("expected one revision conflict");
    expect(rejected.reason).toBeInstanceOf(SyncTransactionError);
    expect(rejected.reason as SyncTransactionError).toMatchObject({ status: 409, code: "revision_conflict" });
    await store.sync.withIdentity(identity, (sync) => sync.beginVaultDeletion(vaultId, 25));
    expect(await store.sync.withIdentity(identity, (sync) => sync.finishVaultDeletion(vaultId))).toBe(true);
  });

  it("enforces FORCE RLS and does not leak transaction-local identity", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres", undefined, true);
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: suffix, workspaceId: `personal:${suffix}`, source: "header" };
    const other: Identity = { userId: `other-${suffix}`, workspaceId: `personal:other-${suffix}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const projectId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const role = await connection!.db.execute<{ rolsuper: boolean; rolbypassrls: boolean }>(sql`
      select rolsuper, rolbypassrls from pg_roles where rolname = current_user
    `);
    expect(role.rows[0]).toEqual({ rolsuper: false, rolbypassrls: false });
    const protectedTables = await connection!.db.execute<{
      schema_name: string;
      table_name: string;
      rls: boolean;
      force_rls: boolean;
    }>(sql`
      select namespace.nspname as schema_name, class.relname as table_name,
        class.relrowsecurity as rls, class.relforcerowsecurity as force_rls
      from pg_class as class
      join pg_namespace as namespace on namespace.oid = class.relnamespace
      where (namespace.nspname, class.relname) in (
        ('core', 'vaults'),
        ('core', 'projects'),
        ('core', 'transaction_receipts'),
        ('content', 'meetings'),
        ('content', 'transcript_segments'),
        ('content', 'transcript_patch_chunks'),
        ('content', 'screenshots'),
        ('content', 'search_documents'),
        ('content', 'search_embeddings')
      )
      order by namespace.nspname, class.relname
    `);
    expect(protectedTables.rows).toHaveLength(9);
    expect(protectedTables.rows.every(({ rls, force_rls }) => rls && force_rls)).toBe(true);
    const legacyOwnerColumns = await connection!.db.execute(sql`
      select 1 from information_schema.columns
      where table_schema in ('core', 'content')
        and table_name in ('vaults', 'meetings', 'transcript_segments', 'screenshots')
        and column_name = 'owner_workspace_id'
    `);
    expect(legacyOwnerColumns.rows).toEqual([]);
    const searchColumns = await connection!.db.execute<{ table_name: string; column_name: string }>(sql`
      select table_name, column_name from information_schema.columns
      where table_schema = 'content'
        and table_name in ('meetings', 'screenshots')
        and column_name in ('search_text', 'search_vector')
      order by table_name, column_name
    `);
    expect(searchColumns.rows).toEqual([]);
    const projectionColumns = await connection!.db.execute<{ column_name: string }>(sql`
      select column_name from information_schema.columns
      where table_schema = 'content' and table_name = 'search_documents'
        and column_name in ('search_text', 'search_vector')
      order by column_name
    `);
    expect(projectionColumns.rows.map(({ column_name }) => column_name)).toEqual(["search_text", "search_vector"]);
    const searchIndexes = await connection!.db.execute<{ indexname: string; indexdef: string }>(sql`
      select indexname, indexdef from pg_indexes
      where schemaname = 'content'
        and (indexname = 'search_documents_search_gin' or indexdef like '%USING hnsw%')
      order by indexname
    `);
    expect(searchIndexes.rows.some(({ indexname }) => indexname === "search_documents_search_gin")).toBe(true);
    expect(searchIndexes.rows.some(({ indexdef }) => indexdef.includes("USING hnsw"))).toBe(true);
    expect(await store.sync.isAvailable()).toBe(true);
    expect(await store.ensureIdentityUser(owner)).toBe(true);
    expect(await store.ensureIdentityUser(other)).toBe(true);
    await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId, [{
      id: crypto.randomUUID(),
      entity: "project",
      action: "create",
      entityId: projectId,
      baseRevision: null,
      data: {
        parentProjectId: null,
        name: "Project",
        description: "",
        projectType: "internal",
        createdAt: new Date(),
      },
    }]));
    expect(await store.sync.withIdentity(owner, (sync) => sync.listProjects(vaultId))).toHaveLength(1);
    expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(true);
    await store.sync.withIdentity(owner, (sync) => commit(sync, vaultId, [{
      id: crypto.randomUUID(),
      entity: "meeting",
      action: "create",
      entityId: meetingId,
      baseRevision: null,
      data: {
        projectId,
        name: "PostgreSQL search",
        description: "projection",
        status: "COMPLETED",
        duration: null,
        recordingStartedAt: null,
        createdAt: new Date(),
        updatedAt: new Date(),
        searchText: "postgresql search projection",
        embeddingText: null,
        embeddingContentHash: null,
      },
    }]));
    expect(await connection!.db.select().from(schema.syncedVaultPermission).where(eq(
      schema.syncedVaultPermission.vaultId,
      vaultId,
    ))).toEqual([expect.objectContaining({
      principalType: "user",
      principalId: owner.userId,
      grantedByUserId: owner.userId,
      role: "owner",
    })]);
    expect(await store.sync.withIdentity(other, (sync) => sync.getVault(vaultId))).toBeNull();
    expect(await store.sync.withIdentity(other, (sync) => sync.listProjects(vaultId))).toEqual([]);
    expect(await store.sync.withIdentity(other, (sync) => sync.listMeetings(vaultId, undefined, 10))).toEqual([]);
    await expect(store.sync.withIdentity(owner, async () => {
      throw new Error("rollback");
    })).rejects.toThrow("rollback");
    const withoutContext = await connection!.db.execute<{ count: string }>(sql`
      select count(*)::text as count from core.vaults where vault_id = ${vaultId}
    `);
    expect(withoutContext.rows[0]?.count).toBe("0");
    const searchWithoutContext = await connection!.db.execute<{ count: string }>(sql`
      select count(*)::text as count from content.search_documents where vault_id = ${vaultId}
    `);
    expect(searchWithoutContext.rows[0]?.count).toBe("0");
    const receiptsWithoutContext = await connection!.db.execute<{ count: string }>(sql`
      select count(*)::text as count from core.transaction_receipts where vault_id = ${vaultId}
    `);
    expect(receiptsWithoutContext.rows[0]?.count).toBe("0");
    await store.sync.withIdentity(owner, (sync) => sync.beginVaultDeletion(vaultId, 25));
    expect(await store.sync.withIdentity(owner, (sync) => sync.finishVaultDeletion(vaultId))).toBe(true);
  });

  it("persists Model Aliases and Better Auth administrators", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres", undefined, true);
    const suffix = crypto.randomUUID();
    const alias = `test-${suffix}`;
    const email = `${suffix}@example.com`;

    expect(await store.createModelAlias({
      alias,
      upstreamModel: "provider/model",
      displayName: null,
      enabled: true,
    })).toBe(true);
    expect(await store.getEnabledModelAlias(alias)).toMatchObject({ alias, upstreamModel: "provider/model" });
    expect(await store.updateModelAlias(alias, {
      upstreamModel: "provider/model-v2",
      displayName: "Test model",
      enabled: false,
    })).toBe(true);
    expect(await store.getEnabledModelAlias(alias)).toBeNull();

    const identity: Identity = {
      userId: suffix,
      workspaceId: `personal:${suffix}`,
      email,
      source: "header",
    };
    expect(await store.ensureIdentityUser(identity)).toBe(true);
    expect(await store.addAdminUser(email)).toMatchObject({ id: suffix });
    expect(await store.isAdminUser(suffix)).toBe(true);
    expect(await store.removeAdminUser(email)).toBe("removed");
    expect(await store.deleteModelAlias(alias)).toBe(true);
  });

  it("grants read-only Vault access through an explicit organization share", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres", undefined, true);
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: `owner-${suffix}`, workspaceId: `personal:owner-${suffix}`, source: "accounts" };
    const member: Identity = { userId: `member-${suffix}`, workspaceId: `personal:member-${suffix}`, source: "accounts" };
    const outsider: Identity = { userId: `outsider-${suffix}`, workspaceId: `personal:outsider-${suffix}`, source: "accounts" };
    const organizationId = `org-${suffix}`;
    const vaultId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const segmentId = crypto.randomUUID();
    const screenshotId = crypto.randomUUID();
    const patchId = crypto.randomUUID();
    const chunkHash = "a".repeat(64);
    const screenshotHash = "b".repeat(64);
    const now = new Date();
    try {
      await connection!.db.insert(schema.user).values([
        { id: owner.userId, name: "Owner", email: `${owner.userId}@example.com`, emailVerified: true },
        { id: member.userId, name: "Member", email: `${member.userId}@example.com`, emailVerified: true },
      ]);
      await connection!.db.insert(schema.organization).values({
        id: organizationId,
        name: organizationId,
        slug: organizationId,
        createdAt: now,
      });
      await connection!.db.insert(schema.member).values([
        { id: `owner-membership-${suffix}`, organizationId, userId: owner.userId, role: "owner", createdAt: now },
        { id: `member-membership-${suffix}`, organizationId, userId: member.userId, role: "member", createdAt: now },
      ]);
      await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(true);
      await store.sync.withIdentity(owner, async (sync) => {
        expect(await sync.putTranscriptChunk(vaultId, meetingId, patchId, 0, chunkHash, [{
          segmentId,
          startTime: now,
          endTime: null,
          text: "original",
          isConfirmed: true,
          audioSource: "system",
          speakerLabel: null,
        }], [])).toBe(true);
        expect(await sync.createScreenshot({
          screenshotId,
          vaultId,
          meetingId,
          capturedAt: now,
          contentType: "image/png",
          storageKey: `meetings/${meetingId}/screenshots/${screenshotId}.png`,
          contentLength: 1,
          contentHash: screenshotHash,
          ocrText: "screen",
          caption: null,
        })).toBe(true);
        await commit(sync, vaultId, [{
          id: crypto.randomUUID(),
          entity: "meeting",
          action: "create",
          entityId: meetingId,
          baseRevision: null,
          data: meetingData(null, now, "Shared meeting", "shared meeting"),
        }, {
          id: crypto.randomUUID(),
          entity: "screenshot",
          action: "upsert",
          entityId: screenshotId,
          baseRevision: null,
          data: {
            meetingId,
            capturedAt: now,
            ocrText: "screen",
            caption: null,
            contentHash: screenshotHash,
            searchText: "screen",
            embeddingText: "screen",
            embeddingContentHash: "screen-hash",
          },
        }, {
          id: patchId,
          entity: "transcript",
          action: "patch",
          entityId: meetingId,
          baseRevision: 0,
          data: {
            patchId,
            segmentCount: 1,
            deletionCount: 0,
            chunks: [{ index: 0, sha256: chunkHash, segmentCount: 1, deletionCount: 0 }],
          },
        }]);
      });
      for (const table of ["meetings", "transcript_segments", "screenshots"] as const) {
        const hidden = await connection!.db.execute<{ count: string }>(
          sql.raw(`select count(*)::text as count from content.${table}`),
        );
        expect(hidden.rows[0]?.count).toBe("0");
      }
      expect(await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "organization", organizationId)))
        .toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId)))
        .toMatchObject({ vaultId, role: "member" });
      const sharingDisabledStore = createPostgresAuthStore(connection!.db, "postgres", undefined, false);
      expect(await sharingDisabledStore.sync.withIdentity(member, (sync) => sync.getVault(vaultId))).toBeNull();
      await store.sync.withIdentity(member, async (sync) => {
        expect(await sync.getMeeting(vaultId, meetingId)).toMatchObject({ name: "Shared meeting" });
        expect(await sync.listMeetings(vaultId, { text: "shared", tokens: ["shared"] }, 10)).toHaveLength(1);
        expect(await sync.listMeetings(vaultId, { text: "missing", tokens: ["missing"] }, 10)).toEqual([]);
        expect(await sync.listTranscript(vaultId, meetingId, 10)).toHaveLength(1);
        expect(await sync.listScreenshots(vaultId, meetingId, undefined, 10)).toHaveLength(1);
        expect(await sync.listScreenshots(vaultId, meetingId, { text: "screen", tokens: ["screen"] }, 10))
          .toHaveLength(1);
      });
      expect(await store.sync.withIdentity(member, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(false);
      expect(await store.sync.withIdentity(outsider, (sync) => sync.getVault(vaultId))).toBeNull();
      expect(await store.sync.withIdentity(
        outsider,
        (sync) => sync.listMeetings(vaultId, { text: "shared", tokens: ["shared"] }, 10),
      )).toEqual([]);
      await connection!.db.delete(schema.member).where(eq(schema.member.userId, member.userId));
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId))).toBeNull();
      await store.deleteVaultPermissionsForOrganization(organizationId);
      await connection!.db.delete(schema.organization).where(eq(schema.organization.id, organizationId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.listPermissions(vaultId)))
        .toEqual([expect.objectContaining({ principalType: "user", role: "owner" })]);
    } finally {
      await store.sync.withIdentity(owner, async (sync) => {
        await sync.deleteMemberPermission(vaultId, "organization", organizationId);
        const screenshots = await sync.beginVaultDeletion(vaultId, 25) ?? [];
        for (const screenshot of screenshots) {
          await sync.deleteScreenshot(vaultId, screenshot.screenshotId, screenshot.storageKey);
        }
        await sync.finishVaultDeletion(vaultId);
      }).catch(() => undefined);
      await connection!.db.delete(schema.organization).where(eq(schema.organization.id, organizationId));
      await connection!.db.delete(schema.user).where(eq(schema.user.id, owner.userId));
      await connection!.db.delete(schema.user).where(eq(schema.user.id, member.userId));
    }
  });

  it("keeps header Vaults private until the owner shares with the external organization", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres", undefined, true);
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: `owner-${suffix}`, workspaceId: `personal:owner-${suffix}`, source: "header" };
    const member: Identity = { userId: `member-${suffix}`, workspaceId: `personal:member-${suffix}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    const teamId = `team-${suffix}`;
    try {
      expect(await store.ensureIdentityUser(owner)).toBe(true);
      expect(await store.ensureIdentityUser(member)).toBe(true);
      await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId))).toBeNull();
      expect(await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(
        vaultId,
        "organization",
        "external",
      ))).toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId)))
        .toMatchObject({ vaultId, role: "member" });
      expect(await store.sync.withIdentity(member, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(false);
      await store.sync.withIdentity(owner, (sync) => sync.deleteMemberPermission(vaultId, "organization", "external"));
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId))).toBeNull();
      await connection!.db.insert(schema.team).values({
        id: teamId,
        name: "Readers",
        organizationId: "external",
        createdAt: new Date(),
        updatedAt: new Date(),
      });
      await connection!.db.insert(schema.teamMember).values({
        id: `${teamId}:${member.userId}`,
        teamId,
        userId: member.userId,
        createdAt: new Date(),
      });
      expect(await store.sync.withIdentity(owner, (sync) => sync.putMemberPermission(vaultId, "team", teamId))).toBe(true);
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId)))
        .toMatchObject({ vaultId, role: "member" });
      await connection!.db.delete(schema.teamMember).where(eq(schema.teamMember.teamId, teamId));
      expect(await store.sync.withIdentity(member, (sync) => sync.getVault(vaultId))).toBeNull();
    } finally {
      await store.sync.withIdentity(owner, async (sync) => {
        await sync.deleteMemberPermission(vaultId, "team", teamId);
        await sync.deleteMemberPermission(vaultId, "organization", "external");
        await sync.beginVaultDeletion(vaultId, 25);
        await sync.finishVaultDeletion(vaultId);
      }).catch(() => undefined);
      await connection!.db.delete(schema.team).where(eq(schema.team.id, teamId));
    }
  });

  it("supports direct user members without granting writes or another owner", async () => {
    const store = createPostgresAuthStore(connection!.db, "postgres", undefined, true);
    const suffix = crypto.randomUUID();
    const owner: Identity = { userId: `owner-${suffix}`, workspaceId: `personal:owner-${suffix}`, source: "header" };
    const member: Identity = { userId: `member-${suffix}`, workspaceId: `personal:member-${suffix}`, source: "header" };
    const vaultId = crypto.randomUUID();
    const meetingId = crypto.randomUUID();
    try {
      expect(await store.ensureIdentityUser(owner)).toBe(true);
      expect(await store.ensureIdentityUser(member)).toBe(true);
      await store.sync.withIdentity(owner, (sync) => createVault(sync, vaultId));
      expect(await store.sync.withIdentity(owner, (sync) => sync.ensureUploadTarget(vaultId, meetingId))).toBe(true);
      await connection!.db.insert(schema.syncedVaultPermission).values({
        vaultId,
        principalType: "user",
        principalId: member.userId,
        role: "member",
        grantedByUserId: owner.userId,
      });
      await expect(connection!.db.insert(schema.syncedVaultPermission).values({
        vaultId,
        principalType: "user",
        principalId: `second-owner-${suffix}`,
        role: "owner",
        grantedByUserId: owner.userId,
      })).rejects.toThrow();
      await expect(connection!.db.insert(schema.syncedVaultPermission).values({
        vaultId,
        principalType: "organization",
        principalId: `org-owner-${suffix}`,
        role: "owner",
        grantedByUserId: owner.userId,
      })).rejects.toThrow();

      await store.sync.withIdentity(member, async (sync) => {
        expect(await sync.getVault(vaultId)).toMatchObject({ role: "member" });
        expect(await sync.listPermissions(vaultId)).toEqual([
          expect.objectContaining({ principalType: "user", principalId: member.userId, role: "member" }),
        ]);
        expect(await sync.ensureUploadTarget(vaultId, meetingId)).toBe(false);
        expect(await sync.beginVaultDeletion(vaultId, 25)).toBeNull();
        expect(await sync.putMemberPermission(vaultId, "organization", "external")).toBe(false);
      });
    } finally {
      await connection!.db.delete(schema.syncedVaultPermission).where(eq(
        schema.syncedVaultPermission.principalId,
        member.userId,
      ));
      await store.sync.withIdentity(owner, async (sync) => {
        await sync.beginVaultDeletion(vaultId, 25);
        await sync.finishVaultDeletion(vaultId);
      }).catch(() => undefined);
    }
  });

  it("paginates artifacts within their owner workspace", async () => {
    const store = createPostgresAuthStore(connection!.db);
    const suffix = crypto.randomUUID().replaceAll("-", "").slice(0, 12);
    const owner = `personal:${suffix}`;
    const first = `019cc4dd-e5c5-7bd4-94e0-${suffix}`;
    const second = `019cc4dd-e5c6-7bd4-94e0-${suffix}`;
    const firstStorageKey = `artifacts/${first}`;
    const secondStorageKey = `artifacts/${second}`;
    try {
      expect(await store.createArtifact({ id: first, ownerWorkspaceId: owner, contentType: "text/plain" }))
        .not.toBeNull();
      expect(await store.createArtifact({ id: second, ownerWorkspaceId: owner, contentType: "text/plain" }))
        .not.toBeNull();
      expect(await store.listArtifacts(owner, undefined, 2)).toEqual([]);
      expect(await store.commitArtifactStorage(first, owner, null, firstStorageKey)).not.toBeNull();
      expect(await store.commitArtifactStorage(second, owner, null, secondStorageKey)).not.toBeNull();
      expect((await store.listArtifacts(owner, undefined, 1)).map(({ id }) => id)).toEqual([second]);
      expect((await store.listArtifacts(owner, second, 1)).map(({ id }) => id)).toEqual([first]);
    } finally {
      const firstArtifact = await store.getArtifact(first);
      const secondArtifact = await store.getArtifact(second);
      await store.deleteArtifact(first, owner, firstArtifact?.storageKey ?? null);
      await store.deleteArtifact(second, owner, secondArtifact?.storageKey ?? null);
    }
  });
});

function createVault(
  sync: IdentitySyncStore,
  vaultId: string,
  operations: SyncTransactionOperation[] = [],
) {
  return commit(sync, vaultId, [{
    id: crypto.randomUUID(),
    entity: "vault",
    action: "create",
    entityId: vaultId,
    baseRevision: null,
    data: { name: "Vault", createdAt: new Date() },
  }, ...operations]);
}

function commit(sync: IdentitySyncStore, vaultId: string, operations: SyncTransactionOperation[]) {
  const id = crypto.randomUUID();
  return sync.commitTransaction({
    schemaVersion: 1,
    id,
    vaultId,
    createdAt: new Date(),
    requestHash: id,
    operations,
  });
}

function meetingData(
  projectId: string | null,
  now: Date,
  name: string,
  searchText: string,
) {
  return {
    projectId,
    name,
    description: "",
    status: "READY",
    duration: 1,
    recordingStartedAt: now,
    createdAt: now,
    updatedAt: now,
    searchText,
    embeddingText: null,
    embeddingContentHash: null,
  };
}
