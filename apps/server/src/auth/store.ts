import type { DBAdapterInstance } from "better-auth";
import { drizzleAdapter } from "@better-auth/drizzle-adapter/relations-v2";
import { and, asc, desc, eq, gt, isNull } from "drizzle-orm";
import { drizzle as drizzleD1 } from "drizzle-orm/d1";

import { gatewayResource, type AppConfig } from "../config";
import * as postgresSchema from "../db/auth-schema";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresAuthSchema from "../db/generated/postgres-auth-schema";
import * as sqliteAuthSchema from "../db/generated/sqlite-auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import { OAUTH_SCOPES } from "./scopes";

export interface DahliaOAuthSession {
  id: string;
  sessionId: string | null;
  createdAt: Date;
  expiresAt: Date;
  userAgent: string | null;
}

export interface ModelAliasRecord {
  alias: string;
  upstreamModel: string;
  displayName: string | null;
  enabled: boolean;
  createdAt: Date;
  updatedAt: Date;
}

export interface ModelAliasInput {
  alias: string;
  upstreamModel: string;
  displayName: string | null;
  enabled: boolean;
}

export type ModelAliasUpdate = Omit<ModelAliasInput, "alias">;

export interface PlatformAdminRecord {
  email: string;
  createdAt: Date;
}

export type ArtifactVisibility = "private" | "public";

export interface ArtifactRecord {
  id: string;
  ownerWorkspaceId: string;
  contentType: string;
  storageKey: string | null;
  visibility: ArtifactVisibility;
  createdAt: Date;
  updatedAt: Date;
}

export interface ArtifactInput {
  id: string;
  ownerWorkspaceId: string;
  contentType: string;
}

/** The subset of Cloudflare D1 referenced by the package's public Worker types. */
export interface D1PreparedStatementLike {
  bind(...values: unknown[]): D1PreparedStatementLike;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
  run(): Promise<{ meta: { changes: number } }>;
}

/** Keeps Cloudflare globals out of declarations consumed by Node applications. */
export interface D1DatabaseLike {
  prepare(query: string): D1PreparedStatementLike;
}

export interface ApplicationStore {
  database: DBAdapterInstance;
  seedDahliaClient(config: AppConfig): Promise<void>;
  listDahliaSessions(userId: string): Promise<DahliaOAuthSession[]>;
  revokeDahliaSession(userId: string, refreshTokenId: string): Promise<boolean>;
  listModelAliases(): Promise<ModelAliasRecord[]>;
  getEnabledModelAlias(alias: string): Promise<ModelAliasRecord | null>;
  createModelAlias(input: ModelAliasInput): Promise<boolean>;
  updateModelAlias(alias: string, update: ModelAliasUpdate): Promise<boolean>;
  deleteModelAlias(alias: string): Promise<boolean>;
  listPlatformAdmins(): Promise<PlatformAdminRecord[]>;
  isPlatformAdmin(email: string): Promise<boolean>;
  addPlatformAdmin(email: string): Promise<boolean>;
  deletePlatformAdmin(email: string): Promise<boolean>;
  getArtifact(id: string): Promise<ArtifactRecord | null>;
  createArtifact(input: ArtifactInput): Promise<boolean>;
  commitArtifactStorage(
    id: string,
    ownerWorkspaceId: string,
    expectedStorageKey: string | null,
    storageKey: string,
  ): Promise<ArtifactRecord | null>;
  updateArtifactVisibility(
    id: string,
    ownerWorkspaceId: string,
    visibility: ArtifactVisibility,
  ): Promise<ArtifactRecord | null>;
  deleteArtifact(id: string, ownerWorkspaceId: string, expectedStorageKey: string | null): Promise<boolean>;
  close?(): Promise<void>;
}

/** @deprecated Use ApplicationStore. */
export type AuthStore = ApplicationStore;

export function createPostgresApplicationStore(db: PostgresDatabase): ApplicationStore {
  return {
    database: drizzleAdapter(db, { provider: "pg", schema: postgresAuthSchema }),
    async seedDahliaClient(config) {
      const now = new Date();
      await db.insert(postgresSchema.oauthClient).values({
        id: "oauth-client-dahlia-macos",
        clientId: "dahlia-macos",
        name: "Dahlia for macOS",
        tokenEndpointAuthMethod: "none",
        applicationType: "native",
        redirectUris: config.oauthRedirectUris,
        grantTypes: ["authorization_code", "refresh_token"],
        responseTypes: ["code"],
        scopes: OAUTH_SCOPES,
        skipConsent: true,
        requirePKCE: true,
        createdAt: now,
        updatedAt: now,
      }).onConflictDoUpdate({
        target: postgresSchema.oauthClient.clientId,
        set: {
          disabled: false,
          name: "Dahlia for macOS",
          tokenEndpointAuthMethod: "none",
          applicationType: "native",
          redirectUris: config.oauthRedirectUris,
          grantTypes: ["authorization_code", "refresh_token"],
          responseTypes: ["code"],
          scopes: OAUTH_SCOPES,
          skipConsent: true,
          requirePKCE: true,
          updatedAt: now,
        },
      });
      const resource = gatewayResource(config);
      const [oauthResource] = await db.select({ id: postgresSchema.oauthResource.id })
        .from(postgresSchema.oauthResource)
        .where(eq(postgresSchema.oauthResource.identifier, resource)).limit(1);
      if (!oauthResource) throw new Error("Dahlia AI Gateway OAuth resource was not created");
      await db.insert(postgresSchema.oauthClientResource).values({
        id: "oauth-client-resource-dahlia-macos",
        clientId: "dahlia-macos",
        resourceId: resource,
        createdAt: now,
      }).onConflictDoUpdate({
        target: postgresSchema.oauthClientResource.id,
        set: { clientId: "dahlia-macos", resourceId: resource },
      });
    },
    async listDahliaSessions(userId) {
      const rows = await db.select({
        id: postgresSchema.oauthRefreshToken.id,
        sessionId: postgresSchema.oauthRefreshToken.sessionId,
        createdAt: postgresSchema.oauthRefreshToken.createdAt,
        expiresAt: postgresSchema.oauthRefreshToken.expiresAt,
        userAgent: postgresSchema.session.userAgent,
      }).from(postgresSchema.oauthRefreshToken)
        .leftJoin(postgresSchema.session, eq(postgresSchema.oauthRefreshToken.sessionId, postgresSchema.session.id))
        .where(and(
          eq(postgresSchema.oauthRefreshToken.userId, userId),
          eq(postgresSchema.oauthRefreshToken.clientId, "dahlia-macos"),
          isNull(postgresSchema.oauthRefreshToken.revoked),
          gt(postgresSchema.oauthRefreshToken.expiresAt, new Date()),
        )).orderBy(desc(postgresSchema.oauthRefreshToken.createdAt));
      return rows.flatMap((row) => row.createdAt && row.expiresAt
        ? [{ ...row, createdAt: row.createdAt, expiresAt: row.expiresAt }]
        : []);
    },
    async revokeDahliaSession(userId, refreshTokenId) {
      const [revoked] = await db.update(postgresSchema.oauthRefreshToken).set({ revoked: new Date() }).where(and(
        eq(postgresSchema.oauthRefreshToken.id, refreshTokenId),
        eq(postgresSchema.oauthRefreshToken.userId, userId),
        eq(postgresSchema.oauthRefreshToken.clientId, "dahlia-macos"),
        isNull(postgresSchema.oauthRefreshToken.revoked),
      )).returning({ id: postgresSchema.oauthRefreshToken.id });
      if (!revoked) return false;
      await db.delete(postgresSchema.oauthAccessToken)
        .where(eq(postgresSchema.oauthAccessToken.refreshId, refreshTokenId));
      return true;
    },
    listModelAliases: () => db.select().from(postgresSchema.modelAlias).orderBy(asc(postgresSchema.modelAlias.alias)),
    async getEnabledModelAlias(alias) {
      const [row] = await db.select().from(postgresSchema.modelAlias)
        .where(and(eq(postgresSchema.modelAlias.alias, alias), eq(postgresSchema.modelAlias.enabled, true))).limit(1);
      return row ?? null;
    },
    async createModelAlias(input) {
      const [created] = await db.insert(postgresSchema.modelAlias).values(input).onConflictDoNothing()
        .returning({ alias: postgresSchema.modelAlias.alias });
      return created !== undefined;
    },
    async updateModelAlias(alias, update) {
      const [updated] = await db.update(postgresSchema.modelAlias).set({ ...update, updatedAt: new Date() })
        .where(eq(postgresSchema.modelAlias.alias, alias)).returning({ alias: postgresSchema.modelAlias.alias });
      return updated !== undefined;
    },
    async deleteModelAlias(alias) {
      const [deleted] = await db.delete(postgresSchema.modelAlias).where(eq(postgresSchema.modelAlias.alias, alias))
        .returning({ alias: postgresSchema.modelAlias.alias });
      return deleted !== undefined;
    },
    listPlatformAdmins: () => db.select().from(postgresSchema.platformAdmin)
      .orderBy(asc(postgresSchema.platformAdmin.email)),
    async isPlatformAdmin(email) {
      const [row] = await db.select({ email: postgresSchema.platformAdmin.email }).from(postgresSchema.platformAdmin)
        .where(eq(postgresSchema.platformAdmin.email, email)).limit(1);
      return row !== undefined;
    },
    async addPlatformAdmin(email) {
      const [created] = await db.insert(postgresSchema.platformAdmin).values({ email }).onConflictDoNothing()
        .returning({ email: postgresSchema.platformAdmin.email });
      return created !== undefined;
    },
    async deletePlatformAdmin(email) {
      const [deleted] = await db.delete(postgresSchema.platformAdmin).where(eq(postgresSchema.platformAdmin.email, email))
        .returning({ email: postgresSchema.platformAdmin.email });
      return deleted !== undefined;
    },
    async getArtifact(id) {
      const [row] = await db.select().from(postgresSchema.artifact)
        .where(eq(postgresSchema.artifact.id, id)).limit(1);
      return (row as ArtifactRecord | undefined) ?? null;
    },
    async createArtifact(input) {
      const [reserved] = await db.insert(postgresSchema.artifactReservation).values({ id: input.id })
        .onConflictDoNothing().returning({ id: postgresSchema.artifactReservation.id });
      if (!reserved) return false;
      const [created] = await db.insert(postgresSchema.artifact).values(input).onConflictDoNothing()
        .returning({ id: postgresSchema.artifact.id });
      return created !== undefined;
    },
    async commitArtifactStorage(id, ownerWorkspaceId, expectedStorageKey, storageKey) {
      const expected = expectedStorageKey === null
        ? isNull(postgresSchema.artifact.storageKey)
        : eq(postgresSchema.artifact.storageKey, expectedStorageKey);
      const [updated] = await db.update(postgresSchema.artifact).set({ storageKey, updatedAt: new Date() }).where(and(
        eq(postgresSchema.artifact.id, id),
        eq(postgresSchema.artifact.ownerWorkspaceId, ownerWorkspaceId),
        expected,
      )).returning();
      return (updated as ArtifactRecord | undefined) ?? null;
    },
    async updateArtifactVisibility(id, ownerWorkspaceId, visibility) {
      const [updated] = await db.update(postgresSchema.artifact).set({ visibility, updatedAt: new Date() })
        .where(and(
          eq(postgresSchema.artifact.id, id),
          eq(postgresSchema.artifact.ownerWorkspaceId, ownerWorkspaceId),
        )).returning();
      return (updated as ArtifactRecord | undefined) ?? null;
    },
    async deleteArtifact(id, ownerWorkspaceId, expectedStorageKey) {
      const expected = expectedStorageKey === null
        ? isNull(postgresSchema.artifact.storageKey)
        : eq(postgresSchema.artifact.storageKey, expectedStorageKey);
      const [deleted] = await db.delete(postgresSchema.artifact).where(and(
        eq(postgresSchema.artifact.id, id),
        eq(postgresSchema.artifact.ownerWorkspaceId, ownerWorkspaceId),
        expected,
      )).returning({ id: postgresSchema.artifact.id });
      return deleted !== undefined;
    },
  };
}

export function createSqliteApplicationStore(db: SQLiteDatabase, transactions = false): ApplicationStore {
  return {
    database: drizzleAdapter(db, { provider: "sqlite", schema: sqliteAuthSchema, transaction: transactions }),
    async seedDahliaClient(config) {
      const now = new Date();
      await db.insert(sqliteSchema.oauthClient).values({
        id: "oauth-client-dahlia-macos",
        clientId: "dahlia-macos",
        name: "Dahlia for macOS",
        tokenEndpointAuthMethod: "none",
        applicationType: "native",
        redirectUris: config.oauthRedirectUris,
        grantTypes: ["authorization_code", "refresh_token"],
        responseTypes: ["code"],
        scopes: [...OAUTH_SCOPES],
        skipConsent: true,
        requirePKCE: true,
        createdAt: now,
        updatedAt: now,
      }).onConflictDoUpdate({
        target: sqliteSchema.oauthClient.clientId,
        set: {
          disabled: false,
          name: "Dahlia for macOS",
          tokenEndpointAuthMethod: "none",
          applicationType: "native",
          redirectUris: config.oauthRedirectUris,
          grantTypes: ["authorization_code", "refresh_token"],
          responseTypes: ["code"],
          scopes: [...OAUTH_SCOPES],
          skipConsent: true,
          requirePKCE: true,
          updatedAt: now,
        },
      });
      const resource = gatewayResource(config);
      const [oauthResource] = await db.select({ id: sqliteSchema.oauthResource.id })
        .from(sqliteSchema.oauthResource)
        .where(eq(sqliteSchema.oauthResource.identifier, resource)).limit(1);
      if (!oauthResource) throw new Error("Dahlia AI Gateway OAuth resource was not created");
      await db.insert(sqliteSchema.oauthClientResource).values({
        id: "oauth-client-resource-dahlia-macos",
        clientId: "dahlia-macos",
        resourceId: resource,
        createdAt: now,
      }).onConflictDoUpdate({
        target: sqliteSchema.oauthClientResource.id,
        set: { clientId: "dahlia-macos", resourceId: resource },
      });
    },
    async listDahliaSessions(userId) {
      const rows = await db.select({
        id: sqliteSchema.oauthRefreshToken.id,
        sessionId: sqliteSchema.oauthRefreshToken.sessionId,
        createdAt: sqliteSchema.oauthRefreshToken.createdAt,
        expiresAt: sqliteSchema.oauthRefreshToken.expiresAt,
        userAgent: sqliteSchema.session.userAgent,
      }).from(sqliteSchema.oauthRefreshToken)
        .leftJoin(sqliteSchema.session, eq(sqliteSchema.oauthRefreshToken.sessionId, sqliteSchema.session.id))
        .where(and(
          eq(sqliteSchema.oauthRefreshToken.userId, userId),
          eq(sqliteSchema.oauthRefreshToken.clientId, "dahlia-macos"),
          isNull(sqliteSchema.oauthRefreshToken.revoked),
          gt(sqliteSchema.oauthRefreshToken.expiresAt, new Date()),
        )).orderBy(desc(sqliteSchema.oauthRefreshToken.createdAt));
      return rows.flatMap((row) => row.createdAt && row.expiresAt
        ? [{ ...row, createdAt: row.createdAt, expiresAt: row.expiresAt }]
        : []);
    },
    async revokeDahliaSession(userId, refreshTokenId) {
      const [revoked] = await db.update(sqliteSchema.oauthRefreshToken).set({ revoked: new Date() }).where(and(
        eq(sqliteSchema.oauthRefreshToken.id, refreshTokenId),
        eq(sqliteSchema.oauthRefreshToken.userId, userId),
        eq(sqliteSchema.oauthRefreshToken.clientId, "dahlia-macos"),
        isNull(sqliteSchema.oauthRefreshToken.revoked),
      )).returning({ id: sqliteSchema.oauthRefreshToken.id });
      if (!revoked) return false;
      await db.delete(sqliteSchema.oauthAccessToken).where(eq(sqliteSchema.oauthAccessToken.refreshId, refreshTokenId));
      return true;
    },
    listModelAliases: () => db.select().from(sqliteSchema.modelAlias).orderBy(asc(sqliteSchema.modelAlias.alias)),
    async getEnabledModelAlias(alias) {
      const [row] = await db.select().from(sqliteSchema.modelAlias)
        .where(and(eq(sqliteSchema.modelAlias.alias, alias), eq(sqliteSchema.modelAlias.enabled, true))).limit(1);
      return row ?? null;
    },
    async createModelAlias(input) {
      const now = new Date();
      const [created] = await db.insert(sqliteSchema.modelAlias).values({ ...input, createdAt: now, updatedAt: now })
        .onConflictDoNothing().returning({ alias: sqliteSchema.modelAlias.alias });
      return created !== undefined;
    },
    async updateModelAlias(alias, update) {
      const [updated] = await db.update(sqliteSchema.modelAlias).set({ ...update, updatedAt: new Date() })
        .where(eq(sqliteSchema.modelAlias.alias, alias)).returning({ alias: sqliteSchema.modelAlias.alias });
      return updated !== undefined;
    },
    async deleteModelAlias(alias) {
      const [deleted] = await db.delete(sqliteSchema.modelAlias).where(eq(sqliteSchema.modelAlias.alias, alias))
        .returning({ alias: sqliteSchema.modelAlias.alias });
      return deleted !== undefined;
    },
    listPlatformAdmins: () => db.select().from(sqliteSchema.platformAdmin)
      .orderBy(asc(sqliteSchema.platformAdmin.email)),
    async isPlatformAdmin(email) {
      const [row] = await db.select({ email: sqliteSchema.platformAdmin.email }).from(sqliteSchema.platformAdmin)
        .where(eq(sqliteSchema.platformAdmin.email, email)).limit(1);
      return row !== undefined;
    },
    async addPlatformAdmin(email) {
      const [created] = await db.insert(sqliteSchema.platformAdmin).values({ email, createdAt: new Date() })
        .onConflictDoNothing().returning({ email: sqliteSchema.platformAdmin.email });
      return created !== undefined;
    },
    async deletePlatformAdmin(email) {
      const [deleted] = await db.delete(sqliteSchema.platformAdmin).where(eq(sqliteSchema.platformAdmin.email, email))
        .returning({ email: sqliteSchema.platformAdmin.email });
      return deleted !== undefined;
    },
    async getArtifact(id) {
      const [row] = await db.select().from(sqliteSchema.artifact)
        .where(eq(sqliteSchema.artifact.id, id)).limit(1);
      return (row as ArtifactRecord | undefined) ?? null;
    },
    async createArtifact(input) {
      const [reserved] = await db.insert(sqliteSchema.artifactReservation).values({ id: input.id })
        .onConflictDoNothing().returning({ id: sqliteSchema.artifactReservation.id });
      if (!reserved) return false;
      const now = new Date();
      const [created] = await db.insert(sqliteSchema.artifact).values({ ...input, createdAt: now, updatedAt: now })
        .onConflictDoNothing().returning({ id: sqliteSchema.artifact.id });
      return created !== undefined;
    },
    async commitArtifactStorage(id, ownerWorkspaceId, expectedStorageKey, storageKey) {
      const expected = expectedStorageKey === null
        ? isNull(sqliteSchema.artifact.storageKey)
        : eq(sqliteSchema.artifact.storageKey, expectedStorageKey);
      const [updated] = await db.update(sqliteSchema.artifact).set({ storageKey, updatedAt: new Date() }).where(and(
        eq(sqliteSchema.artifact.id, id),
        eq(sqliteSchema.artifact.ownerWorkspaceId, ownerWorkspaceId),
        expected,
      )).returning();
      return (updated as ArtifactRecord | undefined) ?? null;
    },
    async updateArtifactVisibility(id, ownerWorkspaceId, visibility) {
      const [updated] = await db.update(sqliteSchema.artifact).set({ visibility, updatedAt: new Date() })
        .where(and(
          eq(sqliteSchema.artifact.id, id),
          eq(sqliteSchema.artifact.ownerWorkspaceId, ownerWorkspaceId),
        )).returning();
      return (updated as ArtifactRecord | undefined) ?? null;
    },
    async deleteArtifact(id, ownerWorkspaceId, expectedStorageKey) {
      const expected = expectedStorageKey === null
        ? isNull(sqliteSchema.artifact.storageKey)
        : eq(sqliteSchema.artifact.storageKey, expectedStorageKey);
      const [deleted] = await db.delete(sqliteSchema.artifact).where(and(
        eq(sqliteSchema.artifact.id, id),
        eq(sqliteSchema.artifact.ownerWorkspaceId, ownerWorkspaceId),
        expected,
      )).returning({ id: sqliteSchema.artifact.id });
      return deleted !== undefined;
    },
  };
}

export function createD1ApplicationStore(database: D1DatabaseLike): ApplicationStore {
  return createSqliteApplicationStore(drizzleD1(database as unknown as D1Database));
}

/** @deprecated Use createPostgresApplicationStore. */
export const createPostgresAuthStore = createPostgresApplicationStore;
/** @deprecated Use createSqliteApplicationStore. */
export const createSqliteAuthStore = createSqliteApplicationStore;
/** @deprecated Use createD1ApplicationStore. */
export const createD1AuthStore = createD1ApplicationStore;
