import {
  and,
  asc,
  desc,
  eq,
  exists,
  inArray,
  isNotNull,
  isNull,
  gt,
  lt,
  ne,
  notInArray,
  or,
  sql,
} from "drizzle-orm";
import type { AnyColumn } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";

import type { Identity } from "../auth/identity";
import type { AppConfig } from "../config";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import { reciprocalRankFusion, SEARCH_CANDIDATE_LIMIT } from "../search/ranking";
import * as postgresSchema from "../db/auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import type {
  IdentitySyncStore,
  MeetingSyncStore,
  SyncProjectView,
  SyncScreenshotRecord,
  SyncSearchQuery,
} from "./types";

type SyncSchema = typeof postgresSchema;
export type SyncSearchBackend = "postgres" | "lakebase" | "sqlite";

export function createPostgresMeetingSyncStore(
  db: PostgresDatabase,
  searchBackend: SyncSearchBackend = "postgres",
  embeddingConfig?: AppConfig["searchEmbedding"],
  sharingEnabled = false,
): MeetingSyncStore {
  let available: Promise<boolean> | undefined;
  const isAvailable = () => available ??= roleSupportsRls(db);
  return {
    isAvailable,
    async withIdentity(identity, action) {
      if (!await isAvailable()) throw new SyncStoreUnavailableError();
      return db.transaction(async (transaction) => {
        await transaction.execute(sql`select set_config('app.user_id', ${identity.userId}, true)`);
        await transaction.execute(sql`select set_config('app.sharing_enabled', ${sharingEnabled ? "true" : "false"}, true)`);
        if (searchBackend === "lakebase") {
          await transaction.execute(sql`select set_config('lakebase_bm25.prefilter', 'on', true)`);
        } else if (searchBackend === "postgres" && embeddingConfig) {
          await transaction.execute(sql`select set_config('hnsw.iterative_scan', 'strict_order', true)`);
        }
        return action(createIdentityStore(
          transaction,
          postgresSchema,
          identity,
          searchBackend,
          embeddingConfig,
          sharingEnabled,
        ));
      });
    },
  };
}

export function createSqliteMeetingSyncStore(
  db: SQLiteDatabase,
  embeddingConfig?: AppConfig["searchEmbedding"],
  sharingEnabled = false,
): MeetingSyncStore {
  return {
    isAvailable: () => Promise.resolve(true),
    withIdentity: (identity, action) => Promise.resolve(db.transaction(async (transaction) => {
      return action(createIdentityStore(
        transaction as unknown as PostgresDatabase,
        sqliteSchema as unknown as SyncSchema,
        identity,
        "sqlite",
        embeddingConfig,
        sharingEnabled,
      ));
    })),
  };
}

export class SyncStoreUnavailableError extends Error {
  constructor() {
    super("sync_store_unavailable");
  }
}

export function createUnavailableMeetingSyncStore(): MeetingSyncStore {
  return {
    isAvailable: () => Promise.resolve(false),
    withIdentity: () => Promise.reject(new SyncStoreUnavailableError()),
  };
}

async function roleSupportsRls(db: PostgresDatabase): Promise<boolean> {
  const client = await db.$client.connect();
  let transaction = false;
  try {
    const role = (await client.query<{ rolsuper: boolean; rolbypassrls: boolean }>(
      "select rolsuper, rolbypassrls from pg_roles where rolname = current_user",
    )).rows[0];
    if (role?.rolsuper !== false || role.rolbypassrls !== false) return false;
    const tables = [
      "core.vaults",
      "core.projects",
      "content.meetings",
      "content.transcript_segments",
      "content.screenshots",
      "content.search_documents",
      "content.search_embeddings",
    ];
    const secured = (await client.query<{ count: number }>(`
      select count(*)::integer as count
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where format('%I.%I', n.nspname, c.relname) = any($1::text[])
        and c.relrowsecurity
        and c.relforcerowsecurity
        and pg_get_userbyid(c.relowner) = current_user
    `, [tables])).rows[0];
    if (secured?.count !== tables.length) return false;

    await client.query("begin");
    transaction = true;
    await client.query("select set_config('app.user_id', 'rls-probe', true)");
    await client.query("select set_config('app.sharing_enabled', 'false', true)");
    await client.query("select vault_id from core.vaults limit 1");
    await client.query("commit");
    transaction = false;
    if (!await identityContextIsEmpty(client)) return false;

    await client.query("begin");
    transaction = true;
    await client.query("select set_config('app.user_id', 'rls-probe', true)");
    await client.query("select set_config('app.sharing_enabled', 'false', true)");
    await client.query("rollback");
    transaction = false;
    return identityContextIsEmpty(client);
  } catch {
    if (transaction) await client.query("rollback").catch(() => undefined);
    return false;
  } finally {
    client.release();
  }
}

async function identityContextIsEmpty(client: import("pg").PoolClient): Promise<boolean> {
  const context = (await client.query<{
    user_id: string | null;
    sharing_enabled: string | null;
  }>(`
    select
      current_setting('app.user_id', true) as user_id,
      current_setting('app.sharing_enabled', true) as sharing_enabled
  `)).rows[0];
  return !context?.user_id && !context?.sharing_enabled;
}

function createIdentityStore(
  db: NodePgDatabase,
  schema: SyncSchema,
  identity: Identity,
  searchBackend: SyncSearchBackend,
  embeddingConfig?: AppConfig["searchEmbedding"],
  sharingEnabled = false,
): IdentitySyncStore {
  const userPrincipalId = identity.userId;
  const ownerAccess = (vault: AnyColumn) => exists(
    db.select({ value: sql`1` }).from(schema.syncedVaultPermission).where(and(
      eq(schema.syncedVaultPermission.vaultId, vault),
      eq(schema.syncedVaultPermission.principalType, "user"),
      eq(schema.syncedVaultPermission.principalId, userPrincipalId),
      eq(schema.syncedVaultPermission.role, "owner"),
    )),
  );
  const matchingMember = () => and(
    eq(schema.syncedVaultPermission.role, "member"),
    or(
      and(
        eq(schema.syncedVaultPermission.principalType, "user"),
        eq(schema.syncedVaultPermission.principalId, userPrincipalId),
      ),
      and(
        eq(schema.syncedVaultPermission.principalType, "organization"),
        exists(db.select({ value: sql`1` }).from(schema.member).where(and(
          eq(schema.member.userId, userPrincipalId),
          eq(schema.member.organizationId, schema.syncedVaultPermission.principalId),
        ))),
      ),
      and(
        eq(schema.syncedVaultPermission.principalType, "team"),
        exists(db.select({ value: sql`1` }).from(schema.teamMember).where(and(
          eq(schema.teamMember.userId, userPrincipalId),
          eq(schema.teamMember.teamId, schema.syncedVaultPermission.principalId),
        ))),
      ),
    ),
  );
  const memberAccess = (vault: AnyColumn) => exists(
    db.select({ value: sql`1` }).from(schema.syncedVaultPermission).where(and(
      eq(schema.syncedVaultPermission.vaultId, vault),
      matchingMember(),
    )),
  );
  const readable = !sharingEnabled
    ? ownerAccess
    : searchBackend === "sqlite"
      ? (vault: AnyColumn) => or(ownerAccess(vault), memberAccess(vault))
      : (vault: AnyColumn) => sql<boolean>`${vault} is not null`;
  const ownedVault = (vaultId: string) => and(
    eq(schema.syncedVault.vaultId, vaultId),
    ownerAccess(schema.syncedVault.vaultId),
  );
  const ownedMeeting = (vaultId: string, meetingId: string) => and(
    eq(schema.syncedMeeting.vaultId, vaultId),
    eq(schema.syncedMeeting.meetingId, meetingId),
    ownerAccess(schema.syncedMeeting.vaultId),
  );
  const readableMeeting = (vaultId: string, meetingId?: string) => and(
    readable(schema.syncedMeeting.vaultId),
    eq(schema.syncedMeeting.vaultId, vaultId),
    ...(meetingId ? [eq(schema.syncedMeeting.meetingId, meetingId)] : []),
  );
  const vaultRole = (vault: AnyColumn) => sql<"owner" | "member">`case when ${ownerAccess(vault)} then 'owner' else 'member' end`;

  async function projectViews(vaultId: string): Promise<SyncProjectView[]> {
    const projects = await db.select().from(schema.syncedProject).where(and(
      readable(schema.syncedProject.vaultId),
      eq(schema.syncedProject.vaultId, vaultId),
    )).orderBy(asc(schema.syncedProject.parentProjectId), asc(schema.syncedProject.name), asc(schema.syncedProject.projectId));
    const meetings = await db.select({ projectId: schema.syncedMeeting.projectId })
      .from(schema.syncedMeeting).where(and(
        readableMeeting(vaultId),
        isNotNull(schema.syncedMeeting.manifestReceivedAt),
        isNull(schema.syncedMeeting.deletingAt),
      ));
    const directCounts = new Map<string, number>();
    for (const { projectId } of meetings) {
      if (projectId) directCounts.set(projectId, (directCounts.get(projectId) ?? 0) + 1);
    }
    const byId = new Map(projects.map((project) => [project.projectId, project]));
    const childrenByParent = new Map<string, typeof projects>();
    for (const project of projects) {
      if (!project.parentProjectId) continue;
      const siblings = childrenByParent.get(project.parentProjectId) ?? [];
      siblings.push(project);
      childrenByParent.set(project.parentProjectId, siblings);
    }
    return projects.map((project) => {
      const root = project.parentProjectId ? byId.get(project.parentProjectId) : project;
      const children = project.parentProjectId ? [] : childrenByParent.get(project.projectId) ?? [];
      return {
        ...project,
        projectType: project.projectType as SyncProjectView["projectType"],
        path: project.parentProjectId && root ? `${root.name}/${project.name}` : project.name,
        rootProjectId: root?.projectId ?? project.projectId,
        effectiveType: (root?.projectType ?? "undefined") as SyncProjectView["effectiveType"],
        typeOwnerProjectId: root?.projectId ?? project.projectId,
        directMeetingCount: directCounts.get(project.projectId) ?? 0,
        subtreeMeetingCount: (directCounts.get(project.projectId) ?? 0)
          + children.reduce((count, child) => count + (directCounts.get(child.projectId) ?? 0), 0),
      };
    });
  }

  type SearchDocumentInput = {
    documentId: string;
    vaultId: string;
    meetingId: string;
    kind: "meeting" | "screenshot";
    searchText: string;
    embeddingText: string | null;
    embeddingContentHash: string | null;
    currentEmbeddingContentHash: string | null;
  };

  async function updateSearchDocuments(inputs: SearchDocumentInput[]): Promise<void> {
    const batchSize = searchBackend === "sqlite" ? 100 : 500;
    const now = new Date();
    for (let offset = 0; offset < inputs.length; offset += batchSize) {
      const batch = inputs.slice(offset, offset + batchSize);
      await db.insert(schema.searchDocument).values(batch.map((input) => ({
        documentId: input.documentId,
        vaultId: input.vaultId,
        meetingId: input.meetingId,
        kind: input.kind,
        searchText: input.searchText,
        embeddingText: input.embeddingText,
        embeddingContentHash: input.embeddingContentHash,
        updatedAt: now,
      }))).onConflictDoUpdate({
        target: [schema.searchDocument.vaultId, schema.searchDocument.documentId],
        set: {
          meetingId: sql`excluded.meeting_id`,
          kind: sql`excluded.kind`,
          searchText: sql`excluded.search_text`,
          embeddingText: sql`excluded.embedding_text`,
          embeddingContentHash: sql`excluded.embedding_content_hash`,
          updatedAt: now,
        },
      });
    }

    const withoutEmbedding = inputs.filter((input) => !embeddingConfig || !input.embeddingText || !input.embeddingContentHash);
    for (let offset = 0; offset < withoutEmbedding.length; offset += batchSize) {
      const batch = withoutEmbedding.slice(offset, offset + batchSize);
      const documentIds = batch.map(({ documentId }) => documentId);
      const vaultId = batch[0]!.vaultId;
      await db.delete(schema.searchIndexJob).where(and(
        eq(schema.searchIndexJob.vaultId, vaultId),
        inArray(schema.searchIndexJob.documentId, documentIds),
      ));
      await db.delete(schema.searchEmbedding).where(and(
        eq(schema.searchEmbedding.vaultId, vaultId),
        inArray(schema.searchEmbedding.documentId, documentIds),
      ));
    }

    if (!embeddingConfig) return;
    const changed = inputs.filter((input) => input.embeddingText
      && input.embeddingContentHash
      && input.currentEmbeddingContentHash !== input.embeddingContentHash);
    const availableAt = new Date(Date.now() + 5_000);
    for (let offset = 0; offset < changed.length; offset += batchSize) {
      await db.insert(schema.searchIndexJob).values(changed.slice(offset, offset + batchSize).map((input) => ({
        vaultId: input.vaultId,
        documentId: input.documentId,
        ownerUserId: userPrincipalId,
        model: embeddingConfig.model,
        dimensions: embeddingConfig.dimensions,
        availableAt,
        updatedAt: now,
      }))).onConflictDoUpdate({
        target: [schema.searchIndexJob.vaultId, schema.searchIndexJob.documentId],
        set: {
          ownerUserId: userPrincipalId,
          model: embeddingConfig.model,
          dimensions: embeddingConfig.dimensions,
          generation: sql`${schema.searchIndexJob.generation} + 1`,
          status: "pending",
          attempts: 0,
          availableAt,
          claimedAt: null,
          leaseExpiresAt: null,
          lastErrorCode: null,
          updatedAt: now,
        },
      });
    }
  }

  function ftsExpressions(query: SyncSearchQuery) {
    if (searchBackend === "sqlite") {
      const match = query.tokens.map((token) => `"${token.replaceAll('"', '""')}"`).join(" AND ");
      const table = sql.identifier("content_search_documents_fts");
      const sourceTable = sql.identifier("content_search_documents");
      return {
        filter: sql`exists (select 1 from ${table} where rowid = ${sourceTable}.rowid and ${table} match ${match})`,
        rank: sql<number>`(select rank from ${table} where rowid = ${sourceTable}.rowid and ${table} match ${match})`,
      };
    }
    const vector = schema.searchDocument.searchVector;
    if (!vector) throw new Error("search_vector_not_configured");
    const tsquery = sql`plainto_tsquery('simple', ${query.text})`;
    return {
      filter: sql`${vector} @@ ${tsquery}`,
      rank: searchBackend === "lakebase"
        ? sql<number>`${vector} <@> to_bm25query(
            to_tsvector('simple', ${query.text}),
            'content.search_documents_search_bm25'::regclass
          )`
        : sql<number>`-${sql`ts_rank_cd(${vector}, ${tsquery})`}`,
    };
  }

  async function ftsDocumentIds(
    vaultId: string,
    meetingId: string | undefined,
    kind: "meeting" | "screenshot",
    query: SyncSearchQuery,
  ): Promise<string[]> {
    const search = ftsExpressions(query);
    const common = and(
      readable(schema.searchDocument.vaultId),
      eq(schema.searchDocument.vaultId, vaultId),
      eq(schema.searchDocument.kind, kind),
      ...(meetingId ? [eq(schema.searchDocument.meetingId, meetingId)] : []),
      search.filter,
    );
    if (kind === "meeting") {
      return (await db.select({ documentId: schema.searchDocument.documentId, rank: search.rank })
        .from(schema.searchDocument)
        .innerJoin(schema.syncedMeeting, and(
          eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
          eq(schema.syncedMeeting.meetingId, schema.searchDocument.documentId),
        ))
        .where(and(common, isNotNull(schema.syncedMeeting.manifestReceivedAt), isNull(schema.syncedMeeting.deletingAt)))
        .orderBy(asc(search.rank), desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId))
        .limit(SEARCH_CANDIDATE_LIMIT)).map(({ documentId }) => documentId);
    }
    return (await db.select({ documentId: schema.searchDocument.documentId, rank: search.rank })
      .from(schema.searchDocument)
      .innerJoin(schema.syncedScreenshot, and(
        eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
        eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
      ))
      .where(and(common, eq(schema.syncedScreenshot.active, true)))
      .orderBy(asc(search.rank), asc(schema.syncedScreenshot.capturedAt), asc(schema.syncedScreenshot.screenshotId))
      .limit(SEARCH_CANDIDATE_LIMIT)).map(({ documentId }) => documentId);
  }

  async function vectorDocumentIds(
    vaultId: string,
    meetingId: string | undefined,
    kind: "meeting" | "screenshot",
    query: SyncSearchQuery,
  ): Promise<string[]> {
    const embedding = query.embedding;
    if (!embedding) return [];
    const common = and(
      readable(schema.searchDocument.vaultId),
      eq(schema.searchDocument.vaultId, vaultId),
      eq(schema.searchDocument.kind, kind),
      ...(meetingId ? [eq(schema.searchDocument.meetingId, meetingId)] : []),
      eq(schema.searchEmbedding.model, embedding.model),
      eq(schema.searchEmbedding.dimensions, embedding.dimensions),
      eq(schema.searchEmbedding.contentHash, schema.searchDocument.embeddingContentHash),
    );
    if (searchBackend === "sqlite") {
      const rows = kind === "meeting"
        ? await db.select({
            documentId: schema.searchDocument.documentId,
            vector: schema.searchEmbedding.embedding,
            sortTime: schema.syncedMeeting.createdAt,
          }).from(schema.searchDocument).innerJoin(schema.searchEmbedding, and(
            eq(schema.searchEmbedding.vaultId, schema.searchDocument.vaultId),
            eq(schema.searchEmbedding.documentId, schema.searchDocument.documentId),
          )).innerJoin(schema.syncedMeeting, and(
            eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
            eq(schema.syncedMeeting.meetingId, schema.searchDocument.documentId),
          )).where(and(common, isNotNull(schema.syncedMeeting.manifestReceivedAt), isNull(schema.syncedMeeting.deletingAt)))
        : await db.select({
            documentId: schema.searchDocument.documentId,
            vector: schema.searchEmbedding.embedding,
            sortTime: schema.syncedScreenshot.capturedAt,
          }).from(schema.searchDocument).innerJoin(schema.searchEmbedding, and(
            eq(schema.searchEmbedding.vaultId, schema.searchDocument.vaultId),
            eq(schema.searchEmbedding.documentId, schema.searchDocument.documentId),
          )).innerJoin(schema.syncedScreenshot, and(
            eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
            eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
          )).where(and(common, eq(schema.syncedScreenshot.active, true)));
      return rows.map(({ documentId, vector, sortTime }) => ({
        documentId,
        sortTime,
        similarity: cosineSimilarity(decodeFloat32(vector as unknown), embedding.vector),
      })).filter(({ similarity }) => Number.isFinite(similarity))
        .sort((left, right) => right.similarity - left.similarity
          || (kind === "meeting"
            ? right.sortTime.getTime() - left.sortTime.getTime()
            : left.sortTime.getTime() - right.sortTime.getTime())
          || left.documentId.localeCompare(right.documentId))
        .slice(0, SEARCH_CANDIDATE_LIMIT).map(({ documentId }) => documentId);
    }
    const dimensions = sql.raw(String(embedding.dimensions));
    const distance = sql<number>`(
      ${schema.searchEmbedding.embedding}::vector(${dimensions})
      <=> ${JSON.stringify(embedding.vector)}::vector(${dimensions})
    )`;
    const base = db.select({ documentId: schema.searchDocument.documentId, distance })
      .from(schema.searchDocument).innerJoin(schema.searchEmbedding, and(
        eq(schema.searchEmbedding.vaultId, schema.searchDocument.vaultId),
        eq(schema.searchEmbedding.documentId, schema.searchDocument.documentId),
      ));
    const rows = kind === "meeting"
      ? await base.innerJoin(schema.syncedMeeting, and(
          eq(schema.syncedMeeting.vaultId, schema.searchDocument.vaultId),
          eq(schema.syncedMeeting.meetingId, schema.searchDocument.documentId),
        )).where(and(common, isNotNull(schema.syncedMeeting.manifestReceivedAt), isNull(schema.syncedMeeting.deletingAt)))
        .orderBy(asc(distance), desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId))
        .limit(SEARCH_CANDIDATE_LIMIT)
      : await base.innerJoin(schema.syncedScreenshot, and(
          eq(schema.syncedScreenshot.vaultId, schema.searchDocument.vaultId),
          eq(schema.syncedScreenshot.screenshotId, schema.searchDocument.documentId),
        )).where(and(common, eq(schema.syncedScreenshot.active, true)))
        .orderBy(asc(distance), asc(schema.syncedScreenshot.capturedAt), asc(schema.syncedScreenshot.screenshotId))
        .limit(SEARCH_CANDIDATE_LIMIT);
    return rows.map(({ documentId }) => documentId);
  }

  async function rankedDocumentIds(
    vaultId: string,
    meetingId: string | undefined,
    kind: "meeting" | "screenshot",
    query: SyncSearchQuery,
  ): Promise<string[]> {
    const [fts, vector] = await Promise.all([
      query.ftsCandidateIds ?? ftsDocumentIds(vaultId, meetingId, kind, query),
      vectorDocumentIds(vaultId, meetingId, kind, query),
    ]);
    return reciprocalRankFusion(fts, vector).map(({ documentId }) => documentId);
  }

  async function commitVaultManifest(manifest: Parameters<IdentitySyncStore["commitVaultManifest"]>[0]): Promise<boolean> {
    const now = new Date();
    await db.insert(schema.syncedVault).values({
      vaultId: manifest.vaultId,
      name: manifest.name,
      createdAt: manifest.createdAt,
      updatedAt: now,
    }).onConflictDoNothing();
    await db.insert(schema.syncedVaultPermission).values({
      vaultId: manifest.vaultId,
      principalType: "user",
      principalId: userPrincipalId,
      role: "owner",
      grantedByUserId: userPrincipalId,
    }).onConflictDoNothing();
    const [owned] = await db.update(schema.syncedVault).set({ name: manifest.name, updatedAt: now })
      .where(ownedVault(manifest.vaultId)).returning({ vaultId: schema.syncedVault.vaultId });
    if (!owned) return false;

    const roots = manifest.projects.filter(({ parentProjectId }) => parentProjectId === null);
    const children = manifest.projects.filter(({ parentProjectId }) => parentProjectId !== null);
    const stagingPrefix = `__dahlia_sync_${crypto.randomUUID()}_`;
    await db.update(schema.syncedProject).set({
      name: sql`${stagingPrefix} || ${schema.syncedProject.projectId}`,
    }).where(and(
      eq(schema.syncedProject.vaultId, manifest.vaultId),
      ownerAccess(schema.syncedProject.vaultId),
    ));
    for (const project of [...roots, ...children]) {
      await db.insert(schema.syncedProject).values(project).onConflictDoNothing();
      const [updated] = await db.update(schema.syncedProject).set({
        parentProjectId: project.parentProjectId,
        name: project.name,
        description: project.description,
        projectType: project.projectType,
        revision: project.revision,
        createdAt: project.createdAt,
      }).where(and(
        eq(schema.syncedProject.vaultId, manifest.vaultId),
        eq(schema.syncedProject.projectId, project.projectId),
        ownerAccess(schema.syncedProject.vaultId),
      )).returning({ projectId: schema.syncedProject.projectId });
      if (!updated) return false;
    }

    const projectIds = manifest.projects.map(({ projectId }) => projectId);
    const obsoleteProjectId = and(
      isNotNull(schema.syncedMeeting.projectId),
      ...(projectIds.length ? [notInArray(schema.syncedMeeting.projectId, projectIds)] : []),
    );
    await db.update(schema.syncedMeeting).set({ projectId: null }).where(and(
      eq(schema.syncedMeeting.vaultId, manifest.vaultId),
      ownerAccess(schema.syncedMeeting.vaultId),
      obsoleteProjectId,
    ));
    const obsolete = and(
      eq(schema.syncedProject.vaultId, manifest.vaultId),
      ownerAccess(schema.syncedProject.vaultId),
      ...(projectIds.length ? [notInArray(schema.syncedProject.projectId, projectIds)] : []),
    );
    await db.delete(schema.syncedProject).where(and(obsolete, isNotNull(schema.syncedProject.parentProjectId)));
    await db.delete(schema.syncedProject).where(obsolete);
    return true;
  }

  async function ensureUploadTarget(vaultId: string, meetingId: string): Promise<boolean> {
    const now = new Date();
    const [vault] = await db.select({ deletingAt: schema.syncedVault.deletingAt })
      .from(schema.syncedVault).where(ownedVault(vaultId)).limit(1);
    if (!vault || vault.deletingAt) return false;
    await db.insert(schema.syncedMeeting).values({
      meetingId,
      vaultId,
      projectId: null,
      name: "",
      description: "",
      status: "PROCESSING_TRANSCRIPT",
      createdAt: now,
      updatedAt: now,
    }).onConflictDoNothing();
    const [meeting] = await db.select({ deletingAt: schema.syncedMeeting.deletingAt })
      .from(schema.syncedMeeting).where(ownedMeeting(vaultId, meetingId)).limit(1);
    return meeting !== undefined && meeting.deletingAt === null;
  }

  return {
    commitVaultManifest,
    ensureUploadTarget,
    async commitManifest(manifest) {
      if (!await ensureUploadTarget(manifest.vaultId, manifest.meetingId)) {
        return { committed: false, missingScreenshotContent: false, obsoleteScreenshots: [] };
      }
      const existingScreenshots = await db.select().from(schema.syncedScreenshot).where(and(
        eq(schema.syncedScreenshot.vaultId, manifest.vaultId),
        eq(schema.syncedScreenshot.meetingId, manifest.meetingId),
      )) as SyncScreenshotRecord[];
      const existingScreenshotById = new Map(existingScreenshots.map((screenshot) => [screenshot.screenshotId, screenshot]));
      if (manifest.screenshots.some(({ screenshotId }) => !existingScreenshotById.has(screenshotId))) {
        return { committed: false, missingScreenshotContent: true, obsoleteScreenshots: [] };
      }
      const currentDocuments = await db.select({
        documentId: schema.searchDocument.documentId,
        hash: schema.searchDocument.embeddingContentHash,
      }).from(schema.searchDocument).where(and(
        eq(schema.searchDocument.vaultId, manifest.vaultId),
        eq(schema.searchDocument.meetingId, manifest.meetingId),
      ));
      const currentDocumentHashes = new Map(currentDocuments.map(({ documentId, hash }) => [documentId, hash]));
      if (manifest.projectId) {
        const [project] = await db.select({ id: schema.syncedProject.projectId }).from(schema.syncedProject).where(and(
          eq(schema.syncedProject.vaultId, manifest.vaultId),
          eq(schema.syncedProject.projectId, manifest.projectId),
          ownerAccess(schema.syncedProject.vaultId),
        )).limit(1);
        if (!project) return { committed: false, missingScreenshotContent: false, obsoleteScreenshots: [] };
      }
      const [updated] = await db.update(schema.syncedMeeting).set({
        projectId: manifest.projectId,
        name: manifest.name,
        description: manifest.description,
        status: manifest.status,
        duration: manifest.duration,
        recordingStartedAt: manifest.recordingStartedAt,
        createdAt: manifest.createdAt,
        updatedAt: manifest.updatedAt,
        summaryTitle: manifest.summaryTitle,
        summaryDocument: manifest.summaryDocument,
        summaryCreatedAt: manifest.summaryCreatedAt,
        activeTranscriptGeneration: manifest.activeTranscriptGeneration,
        manifestReceivedAt: new Date(),
      }).where(and(ownedMeeting(manifest.vaultId, manifest.meetingId), isNull(schema.syncedMeeting.deletingAt)))
        .returning({ meetingId: schema.syncedMeeting.meetingId });
      if (!updated) return { committed: false, missingScreenshotContent: false, obsoleteScreenshots: [] };
      const searchDocuments: SearchDocumentInput[] = [{
        documentId: manifest.meetingId,
        vaultId: manifest.vaultId,
        meetingId: manifest.meetingId,
        kind: "meeting",
        searchText: manifest.searchText,
        embeddingText: manifest.embeddingText,
        embeddingContentHash: manifest.embeddingContentHash,
        currentEmbeddingContentHash: currentDocumentHashes.get(manifest.meetingId) ?? null,
      }];

      if (manifest.activeTranscriptGeneration) {
        await db.delete(schema.syncedTranscriptSegment).where(and(
          eq(schema.syncedTranscriptSegment.vaultId, manifest.vaultId),
          eq(schema.syncedTranscriptSegment.meetingId, manifest.meetingId),
          ne(schema.syncedTranscriptSegment.generation, manifest.activeTranscriptGeneration),
        ));
      } else {
        await db.delete(schema.syncedTranscriptSegment).where(and(
          eq(schema.syncedTranscriptSegment.vaultId, manifest.vaultId),
          eq(schema.syncedTranscriptSegment.meetingId, manifest.meetingId),
        ));
      }

      const now = new Date();
      const screenshotBatchSize = searchBackend === "sqlite" ? 100 : 500;
      for (let offset = 0; offset < manifest.screenshots.length; offset += screenshotBatchSize) {
        const batch = manifest.screenshots.slice(offset, offset + screenshotBatchSize);
        await db.insert(schema.syncedScreenshot).values(batch.map((screenshot) => ({
          ...existingScreenshotById.get(screenshot.screenshotId)!,
          capturedAt: screenshot.capturedAt,
          active: true,
          ocrText: screenshot.ocrText,
          caption: screenshot.caption,
          updatedAt: now,
        }))).onConflictDoUpdate({
          target: schema.syncedScreenshot.screenshotId,
          set: {
            capturedAt: sql`excluded.captured_at`,
            active: true,
            ocrText: sql`excluded.ocr_text`,
            caption: sql`excluded.caption`,
            updatedAt: now,
          },
        });
        searchDocuments.push(...batch.map((screenshot) => ({
          documentId: screenshot.screenshotId,
          vaultId: manifest.vaultId,
          meetingId: manifest.meetingId,
          kind: "screenshot" as const,
          searchText: screenshot.searchText,
          embeddingText: screenshot.embeddingText,
          embeddingContentHash: screenshot.embeddingContentHash,
          currentEmbeddingContentHash: currentDocumentHashes.get(screenshot.screenshotId) ?? null,
        })));
      }
      await updateSearchDocuments(searchDocuments);

      const screenshotIds = manifest.screenshots.map((screenshot) => screenshot.screenshotId);
      const activeScreenshotIds = new Set(screenshotIds);
      const obsolete = existingScreenshots.filter(({ screenshotId }) => !activeScreenshotIds.has(screenshotId));
      if (obsolete.length > 0) {
        const obsoleteIds = obsolete.map(({ screenshotId }) => screenshotId);
        await db.update(schema.syncedScreenshot).set({ active: false, updatedAt: now }).where(and(
          eq(schema.syncedScreenshot.vaultId, manifest.vaultId),
          inArray(schema.syncedScreenshot.screenshotId, obsoleteIds),
        ));
        await db.delete(schema.searchIndexJob).where(and(
          eq(schema.searchIndexJob.vaultId, manifest.vaultId),
          inArray(schema.searchIndexJob.documentId, obsoleteIds),
        ));
        await db.delete(schema.searchDocument).where(and(
          eq(schema.searchDocument.vaultId, manifest.vaultId),
          inArray(schema.searchDocument.documentId, obsoleteIds),
        ));
      }
      return { committed: true, missingScreenshotContent: false, obsoleteScreenshots: obsolete };
    },
    async putTranscriptChunk(vaultId, meetingId, generation, segments) {
      if (!await ensureUploadTarget(vaultId, meetingId)) return false;
      if (segments.length === 0) return true;
      await db.insert(schema.syncedTranscriptSegment).values(segments.map((segment) => ({
        ...segment,
        vaultId,
        meetingId,
        generation,
      }))).onConflictDoUpdate({
        target: [
          schema.syncedTranscriptSegment.vaultId,
          schema.syncedTranscriptSegment.meetingId,
          schema.syncedTranscriptSegment.generation,
          schema.syncedTranscriptSegment.segmentId,
        ],
        set: {
          startTime: sql`excluded.start_time`,
          endTime: sql`excluded.end_time`,
          text: sql`excluded.text`,
          isConfirmed: sql`excluded.is_confirmed`,
          audioSource: sql`excluded.audio_source`,
          speakerLabel: sql`excluded.speaker_label`,
        },
      });
      return true;
    },
    async getScreenshot(vaultId, meetingId, screenshotId, activeOnly = false) {
      const [row] = await db.select().from(schema.syncedScreenshot).where(and(
        readable(schema.syncedScreenshot.vaultId),
        eq(schema.syncedScreenshot.vaultId, vaultId),
        eq(schema.syncedScreenshot.meetingId, meetingId),
        eq(schema.syncedScreenshot.screenshotId, screenshotId),
        ...(activeOnly ? [eq(schema.syncedScreenshot.active, true)] : []),
      )).limit(1);
      return (row as SyncScreenshotRecord | undefined) ?? null;
    },
    async createScreenshot(input) {
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(ownedVault(input.vaultId)).limit(1);
      if (!vault) return false;
      const [created] = await db.insert(schema.syncedScreenshot).values({
        ...input,
        active: false,
        createdAt: new Date(),
        updatedAt: new Date(),
      }).onConflictDoNothing().returning({ screenshotId: schema.syncedScreenshot.screenshotId });
      return created !== undefined;
    },
    async deleteScreenshot(vaultId, screenshotId, storageKey) {
      await db.delete(schema.searchIndexJob).where(and(
        eq(schema.searchIndexJob.vaultId, vaultId),
        eq(schema.searchIndexJob.documentId, screenshotId),
      ));
      await db.delete(schema.searchDocument).where(and(
        eq(schema.searchDocument.vaultId, vaultId),
        eq(schema.searchDocument.documentId, screenshotId),
      ));
      const [deleted] = await db.delete(schema.syncedScreenshot).where(and(
        eq(schema.syncedScreenshot.vaultId, vaultId),
        eq(schema.syncedScreenshot.screenshotId, screenshotId),
        eq(schema.syncedScreenshot.storageKey, storageKey),
        ownerAccess(schema.syncedScreenshot.vaultId),
      )).returning({ screenshotId: schema.syncedScreenshot.screenshotId });
      return deleted !== undefined;
    },
    async listVaults() {
      const rows = await db.select({
        vaultId: schema.syncedVault.vaultId,
        name: schema.syncedVault.name,
        createdAt: schema.syncedVault.createdAt,
        updatedAt: schema.syncedVault.updatedAt,
        role: vaultRole(schema.syncedVault.vaultId),
      }).from(schema.syncedVault).where(and(
        readable(schema.syncedVault.vaultId),
        isNull(schema.syncedVault.deletingAt),
      )).orderBy(desc(schema.syncedVault.updatedAt));
      return rows;
    },
    async getVault(vaultId) {
      const [row] = await db.select({
        vaultId: schema.syncedVault.vaultId,
        name: schema.syncedVault.name,
        createdAt: schema.syncedVault.createdAt,
        updatedAt: schema.syncedVault.updatedAt,
        role: vaultRole(schema.syncedVault.vaultId),
      }).from(schema.syncedVault).where(and(
        readable(schema.syncedVault.vaultId),
        eq(schema.syncedVault.vaultId, vaultId),
        isNull(schema.syncedVault.deletingAt),
      )).limit(1);
      return row ?? null;
    },
    async listProjects(vaultId) {
      return projectViews(vaultId);
    },
    async getProject(vaultId, projectId) {
      return (await projectViews(vaultId)).find((project) => project.projectId === projectId) ?? null;
    },
    async listMeetings(vaultId, query, limit, projectId, cursor) {
      if (query && query.tokens.length === 0) return [];
      const projectIds = projectId
        ? (await projectViews(vaultId)).filter((project) =>
            project.projectId === projectId || project.parentProjectId === projectId).map((project) => project.projectId)
        : undefined;
      if (projectId && projectIds?.length === 0) return [];
      const filter = and(
        readableMeeting(vaultId),
        ...(projectIds ? [inArray(schema.syncedMeeting.projectId, projectIds)] : []),
        ...(cursor ? [or(
          lt(schema.syncedMeeting.createdAt, cursor.createdAt),
          and(
            eq(schema.syncedMeeting.createdAt, cursor.createdAt),
            lt(schema.syncedMeeting.meetingId, cursor.meetingId),
          ),
        )] : []),
        isNotNull(schema.syncedMeeting.manifestReceivedAt),
        isNull(schema.syncedMeeting.deletingAt),
      );
      if (!query) {
        return db.select(meetingSelection(schema)).from(schema.syncedMeeting)
          .where(filter).orderBy(desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId))
          .limit(limit);
      }
      const ids = await rankedDocumentIds(vaultId, undefined, "meeting", query);
      if (ids.length === 0) return [];
      const rows = await db.select(meetingSelection(schema)).from(schema.syncedMeeting)
        .where(and(filter, inArray(schema.syncedMeeting.meetingId, ids)))
        .orderBy(desc(schema.syncedMeeting.createdAt), desc(schema.syncedMeeting.meetingId));
      const rank = new Map(ids.map((id, index) => [id, index]));
      return rows.sort((left, right) => rank.get(left.meetingId)! - rank.get(right.meetingId)!).slice(0, limit);
    },
    async getMeeting(vaultId, meetingId) {
      const [row] = await db.select(meetingSelection(schema)).from(schema.syncedMeeting).where(and(
        readableMeeting(vaultId, meetingId),
        isNotNull(schema.syncedMeeting.manifestReceivedAt),
        isNull(schema.syncedMeeting.deletingAt),
      )).limit(1);
      return row ?? null;
    },
    async listTranscript(vaultId, meetingId, limit, cursor) {
      const [meeting] = await db.select({ generation: schema.syncedMeeting.activeTranscriptGeneration })
        .from(schema.syncedMeeting).where(and(
          readableMeeting(vaultId, meetingId),
          isNotNull(schema.syncedMeeting.manifestReceivedAt),
          isNull(schema.syncedMeeting.deletingAt),
        )).limit(1);
      if (!meeting?.generation) return [];
      return db.select({
        segmentId: schema.syncedTranscriptSegment.segmentId,
        startTime: schema.syncedTranscriptSegment.startTime,
        endTime: schema.syncedTranscriptSegment.endTime,
        text: schema.syncedTranscriptSegment.text,
        isConfirmed: schema.syncedTranscriptSegment.isConfirmed,
        audioSource: schema.syncedTranscriptSegment.audioSource,
        speakerLabel: schema.syncedTranscriptSegment.speakerLabel,
      }).from(schema.syncedTranscriptSegment).where(and(
        readable(schema.syncedTranscriptSegment.vaultId),
        eq(schema.syncedTranscriptSegment.vaultId, vaultId),
        eq(schema.syncedTranscriptSegment.meetingId, meetingId),
        eq(schema.syncedTranscriptSegment.generation, meeting.generation),
        ...(cursor ? [or(
          gt(schema.syncedTranscriptSegment.startTime, cursor.startTime),
          and(
            eq(schema.syncedTranscriptSegment.startTime, cursor.startTime),
            gt(schema.syncedTranscriptSegment.segmentId, cursor.segmentId),
          ),
        )] : []),
      )).orderBy(asc(schema.syncedTranscriptSegment.startTime), asc(schema.syncedTranscriptSegment.segmentId))
        .limit(limit);
    },
    async listScreenshots(vaultId, meetingId, query, limit, cursor) {
      if (query && query.tokens.length === 0) return [];
      const [meeting] = await db.select({ id: schema.syncedMeeting.meetingId })
        .from(schema.syncedMeeting).where(and(
          readableMeeting(vaultId, meetingId),
          isNotNull(schema.syncedMeeting.manifestReceivedAt),
          isNull(schema.syncedMeeting.deletingAt),
        )).limit(1);
      if (!meeting) return [];
      const filter = and(
        readable(schema.syncedScreenshot.vaultId),
        eq(schema.syncedScreenshot.vaultId, vaultId),
        eq(schema.syncedScreenshot.meetingId, meetingId),
        eq(schema.syncedScreenshot.active, true),
        ...(cursor ? [or(
          gt(schema.syncedScreenshot.capturedAt, cursor.capturedAt),
          and(
            eq(schema.syncedScreenshot.capturedAt, cursor.capturedAt),
            gt(schema.syncedScreenshot.screenshotId, cursor.screenshotId),
          ),
        )] : []),
      );
      if (!query) {
        return db.select(screenshotSelection(schema)).from(schema.syncedScreenshot).where(filter)
          .orderBy(asc(schema.syncedScreenshot.capturedAt), asc(schema.syncedScreenshot.screenshotId)).limit(limit);
      }
      const ids = await rankedDocumentIds(vaultId, meetingId, "screenshot", query);
      if (ids.length === 0) return [];
      const rows = await db.select(screenshotSelection(schema)).from(schema.syncedScreenshot)
        .where(and(filter, inArray(schema.syncedScreenshot.screenshotId, ids)))
        .orderBy(asc(schema.syncedScreenshot.capturedAt), asc(schema.syncedScreenshot.screenshotId));
      const rank = new Map(ids.map((id, index) => [id, index]));
      return rows.sort((left, right) => rank.get(left.screenshotId)! - rank.get(right.screenshotId)!).slice(0, limit);
    },
    async listPermissions(vaultId) {
      const [vault] = await db.select({ role: vaultRole(schema.syncedVault.vaultId) })
        .from(schema.syncedVault).where(and(
          readable(schema.syncedVault.vaultId),
          eq(schema.syncedVault.vaultId, vaultId),
          isNull(schema.syncedVault.deletingAt),
        )).limit(1);
      if (!vault) return null;
      return db.select({
        vaultId: schema.syncedVaultPermission.vaultId,
        principalType: schema.syncedVaultPermission.principalType,
        principalId: schema.syncedVaultPermission.principalId,
        role: schema.syncedVaultPermission.role,
        createdAt: schema.syncedVaultPermission.createdAt,
      }).from(schema.syncedVaultPermission).where(and(
        eq(schema.syncedVaultPermission.vaultId, vaultId),
        ...(vault.role === "owner" ? [] : [matchingMember()]),
      )) as Promise<import("./types").VaultPermissionRecord[]>;
    },
    async putMemberPermission(vaultId, principalType, principalId) {
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(and(ownedVault(vaultId), isNull(schema.syncedVault.deletingAt))).limit(1);
      if (!vault) return false;
      if (principalType === "organization") {
        if (identity.source === "header" && principalId !== "external") return false;
        const [membership] = await db.select({ id: schema.member.id }).from(schema.member).where(and(
          eq(schema.member.userId, userPrincipalId),
          eq(schema.member.organizationId, principalId),
        )).limit(1);
        if (!membership) return false;
      } else if (principalType === "team") {
        const [team] = await db.select({ id: schema.team.id }).from(schema.team)
          .innerJoin(schema.member, and(
            eq(schema.member.organizationId, schema.team.organizationId),
            eq(schema.member.userId, userPrincipalId),
          ))
          .where(eq(schema.team.id, principalId)).limit(1);
        if (!team) return false;
      } else {
        return false;
      }
      await db.insert(schema.syncedVaultPermission).values({
        vaultId,
        principalType,
        principalId,
        role: "member",
        grantedByUserId: userPrincipalId,
      }).onConflictDoNothing();
      return true;
    },
    async deleteMemberPermission(vaultId, principalType, principalId) {
      const [vault] = await db.select({ id: schema.syncedVault.vaultId }).from(schema.syncedVault)
        .where(ownedVault(vaultId)).limit(1);
      if (!vault || principalType === "user") return false;
      const [deleted] = await db.delete(schema.syncedVaultPermission).where(and(
        eq(schema.syncedVaultPermission.vaultId, vaultId),
        eq(schema.syncedVaultPermission.principalType, principalType),
        eq(schema.syncedVaultPermission.principalId, principalId),
        eq(schema.syncedVaultPermission.role, "member"),
      )).returning({ vaultId: schema.syncedVaultPermission.vaultId });
      return deleted !== undefined;
    },
    async beginMeetingDeletion(vaultId, meetingId, limit) {
      const [meeting] = await db.update(schema.syncedMeeting).set({ deletingAt: new Date() })
        .where(ownedMeeting(vaultId, meetingId)).returning({ meetingId: schema.syncedMeeting.meetingId });
      if (!meeting) return null;
      await db.delete(schema.searchIndexJob).where(and(
        eq(schema.searchIndexJob.vaultId, vaultId),
        inArray(
          schema.searchIndexJob.documentId,
          db.select({ id: schema.searchDocument.documentId }).from(schema.searchDocument).where(and(
            eq(schema.searchDocument.vaultId, vaultId),
            eq(schema.searchDocument.meetingId, meetingId),
          )),
        ),
      ));
      return db.select(screenshotSelection(schema)).from(schema.syncedScreenshot).where(and(
        eq(schema.syncedScreenshot.vaultId, vaultId),
        eq(schema.syncedScreenshot.meetingId, meetingId),
      )).orderBy(asc(schema.syncedScreenshot.screenshotId)).limit(limit);
    },
    async finishMeetingDeletion(vaultId, meetingId) {
      const [remaining] = await db.select({ id: schema.syncedScreenshot.screenshotId })
        .from(schema.syncedScreenshot).where(and(
          eq(schema.syncedScreenshot.vaultId, vaultId),
          eq(schema.syncedScreenshot.meetingId, meetingId),
          ownerAccess(schema.syncedScreenshot.vaultId),
        )).limit(1);
      if (remaining) return false;
      const documents = await db.select({ id: schema.searchDocument.documentId })
        .from(schema.searchDocument).where(and(
          eq(schema.searchDocument.vaultId, vaultId),
          eq(schema.searchDocument.meetingId, meetingId),
        ));
      if (documents.length > 0) {
        await db.delete(schema.searchIndexJob).where(and(
          eq(schema.searchIndexJob.vaultId, vaultId),
          inArray(schema.searchIndexJob.documentId, documents.map(({ id }) => id)),
        ));
      }
      const [deleted] = await db.delete(schema.syncedMeeting).where(ownedMeeting(vaultId, meetingId))
        .returning({ meetingId: schema.syncedMeeting.meetingId });
      return deleted !== undefined;
    },
    async beginVaultDeletion(vaultId, limit) {
      const [vault] = await db.update(schema.syncedVault).set({ deletingAt: new Date() })
        .where(ownedVault(vaultId)).returning({ vaultId: schema.syncedVault.vaultId });
      if (!vault) return null;
      await db.delete(schema.searchIndexJob).where(eq(schema.searchIndexJob.vaultId, vaultId));
      await db.update(schema.syncedMeeting).set({ deletingAt: new Date() }).where(and(
        eq(schema.syncedMeeting.vaultId, vaultId),
        ownerAccess(schema.syncedMeeting.vaultId),
      ));
      return db.select(screenshotSelection(schema)).from(schema.syncedScreenshot).where(and(
        eq(schema.syncedScreenshot.vaultId, vaultId),
      )).orderBy(asc(schema.syncedScreenshot.screenshotId)).limit(limit);
    },
    async finishVaultDeletion(vaultId) {
      const [remaining] = await db.select({ id: schema.syncedScreenshot.screenshotId })
        .from(schema.syncedScreenshot).where(and(
          eq(schema.syncedScreenshot.vaultId, vaultId),
          ownerAccess(schema.syncedScreenshot.vaultId),
        )).limit(1);
      if (remaining) return false;
      const [deleted] = await db.delete(schema.syncedVault).where(ownedVault(vaultId))
        .returning({ vaultId: schema.syncedVault.vaultId });
      return deleted !== undefined;
    },
  };
}

function meetingSelection(schema: SyncSchema) {
  return {
    meetingId: schema.syncedMeeting.meetingId,
    vaultId: schema.syncedMeeting.vaultId,
    projectId: schema.syncedMeeting.projectId,
    name: schema.syncedMeeting.name,
    description: schema.syncedMeeting.description,
    status: schema.syncedMeeting.status,
    duration: schema.syncedMeeting.duration,
    recordingStartedAt: schema.syncedMeeting.recordingStartedAt,
    createdAt: schema.syncedMeeting.createdAt,
    updatedAt: schema.syncedMeeting.updatedAt,
    summaryTitle: schema.syncedMeeting.summaryTitle,
    summaryDocument: schema.syncedMeeting.summaryDocument,
    summaryCreatedAt: schema.syncedMeeting.summaryCreatedAt,
    activeTranscriptGeneration: schema.syncedMeeting.activeTranscriptGeneration,
  };
}

function screenshotSelection(schema: SyncSchema) {
  return {
    screenshotId: schema.syncedScreenshot.screenshotId,
    vaultId: schema.syncedScreenshot.vaultId,
    meetingId: schema.syncedScreenshot.meetingId,
    capturedAt: schema.syncedScreenshot.capturedAt,
    contentType: schema.syncedScreenshot.contentType,
    storageKey: schema.syncedScreenshot.storageKey,
    contentLength: schema.syncedScreenshot.contentLength,
    ocrText: schema.syncedScreenshot.ocrText,
    caption: schema.syncedScreenshot.caption,
  };
}

function decodeFloat32(value: unknown): number[] {
  if (!(value instanceof Uint8Array) && !(value instanceof ArrayBuffer)) return [];
  const bytes = value instanceof Uint8Array
    ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
    : new Uint8Array(value);
  if (bytes.byteLength % 4 !== 0) return [];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return Array.from({ length: bytes.byteLength / 4 }, (_, index) => view.getFloat32(index * 4, true));
}

function cosineSimilarity(left: readonly number[], right: readonly number[]): number {
  if (left.length !== right.length || left.length === 0) return Number.NaN;
  let dot = 0;
  let leftNorm = 0;
  let rightNorm = 0;
  for (let index = 0; index < left.length; index++) {
    dot += left[index]! * right[index]!;
    leftNorm += left[index]! ** 2;
    rightNorm += right[index]! ** 2;
  }
  return leftNorm && rightNorm ? dot / Math.sqrt(leftNorm * rightNorm) : Number.NaN;
}
