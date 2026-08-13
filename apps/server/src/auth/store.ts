import type { DatabaseSync } from "node:sqlite";

import type { DBAdapterInstance } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { and, asc, desc, eq, gt, isNull } from "drizzle-orm";

import { gatewayResource, type AppConfig } from "../config";
import type { Database } from "../db/client";
import * as authSchema from "../db/auth-schema";
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

/** The subset of Cloudflare D1 used by Dahlia Server's SQLite adapter. */
export interface D1PreparedStatementLike {
  bind(...values: unknown[]): D1PreparedStatementLike;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
  run(): Promise<{ meta: { changes: number } }>;
}

/** A package-owned D1 shape so Node consumers do not need Cloudflare globals. */
export interface D1DatabaseLike {
  prepare(query: string): D1PreparedStatementLike;
}

export interface AuthStore {
  database: DBAdapterInstance | DatabaseSync | D1DatabaseLike;
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
  close?(): Promise<void>;
}

export function createPostgresAuthStore(db: Database): AuthStore {
  return {
    database: drizzleAdapter(db, { provider: "pg", schema: authSchema }),
    async seedDahliaClient(config) {
      const now = new Date();
      await db
        .insert(authSchema.oauthClient)
        .values({
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
        })
        .onConflictDoUpdate({
          target: authSchema.oauthClient.clientId,
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
      const oauthResource = await db.query.oauthResource.findFirst({
        columns: { id: true },
        where: eq(authSchema.oauthResource.identifier, resource),
      });
      if (!oauthResource) throw new Error("Dahlia AI Gateway OAuth resource was not created");
      await db
        .insert(authSchema.oauthClientResource)
        .values({
          id: "oauth-client-resource-dahlia-macos",
          clientId: "dahlia-macos",
          resourceId: resource,
          createdAt: now,
        })
        .onConflictDoUpdate({
          target: authSchema.oauthClientResource.id,
          set: { clientId: "dahlia-macos", resourceId: resource },
        });
    },
    async listDahliaSessions(userId) {
      const rows = await db
        .select({
          id: authSchema.oauthRefreshToken.id,
          sessionId: authSchema.oauthRefreshToken.sessionId,
          createdAt: authSchema.oauthRefreshToken.createdAt,
          expiresAt: authSchema.oauthRefreshToken.expiresAt,
          userAgent: authSchema.session.userAgent,
        })
        .from(authSchema.oauthRefreshToken)
        .leftJoin(authSchema.session, eq(authSchema.oauthRefreshToken.sessionId, authSchema.session.id))
        .where(
          and(
            eq(authSchema.oauthRefreshToken.userId, userId),
            eq(authSchema.oauthRefreshToken.clientId, "dahlia-macos"),
            isNull(authSchema.oauthRefreshToken.revoked),
            gt(authSchema.oauthRefreshToken.expiresAt, new Date()),
          ),
        )
        .orderBy(desc(authSchema.oauthRefreshToken.createdAt));
      return rows.flatMap((row) => row.createdAt && row.expiresAt ? [{ ...row, createdAt: row.createdAt, expiresAt: row.expiresAt }] : []);
    },
    async revokeDahliaSession(userId, refreshTokenId) {
      const [revoked] = await db
        .update(authSchema.oauthRefreshToken)
        .set({ revoked: new Date() })
        .where(
          and(
            eq(authSchema.oauthRefreshToken.id, refreshTokenId),
            eq(authSchema.oauthRefreshToken.userId, userId),
            eq(authSchema.oauthRefreshToken.clientId, "dahlia-macos"),
            isNull(authSchema.oauthRefreshToken.revoked),
          ),
        )
        .returning({ id: authSchema.oauthRefreshToken.id });
      if (!revoked) return false;
      await db.delete(authSchema.oauthAccessToken).where(eq(authSchema.oauthAccessToken.refreshId, refreshTokenId));
      return true;
    },
    async listModelAliases() {
      return db.select().from(authSchema.modelAlias).orderBy(asc(authSchema.modelAlias.alias));
    },
    async getEnabledModelAlias(alias) {
      const [row] = await db.select().from(authSchema.modelAlias)
        .where(and(eq(authSchema.modelAlias.alias, alias), eq(authSchema.modelAlias.enabled, true))).limit(1);
      return row ?? null;
    },
    async createModelAlias(input) {
      const [created] = await db.insert(authSchema.modelAlias).values(input).onConflictDoNothing()
        .returning({ alias: authSchema.modelAlias.alias });
      return created !== undefined;
    },
    async updateModelAlias(alias, update) {
      const [updated] = await db.update(authSchema.modelAlias).set({ ...update, updatedAt: new Date() })
        .where(eq(authSchema.modelAlias.alias, alias)).returning({ alias: authSchema.modelAlias.alias });
      return updated !== undefined;
    },
    async deleteModelAlias(alias) {
      const [deleted] = await db.delete(authSchema.modelAlias).where(eq(authSchema.modelAlias.alias, alias))
        .returning({ alias: authSchema.modelAlias.alias });
      return deleted !== undefined;
    },
    async listPlatformAdmins() {
      return db.select().from(authSchema.platformAdmin).orderBy(asc(authSchema.platformAdmin.email));
    },
    async isPlatformAdmin(email) {
      const [row] = await db.select({ email: authSchema.platformAdmin.email }).from(authSchema.platformAdmin)
        .where(eq(authSchema.platformAdmin.email, email)).limit(1);
      return row !== undefined;
    },
    async addPlatformAdmin(email) {
      const [created] = await db.insert(authSchema.platformAdmin).values({ email }).onConflictDoNothing()
        .returning({ email: authSchema.platformAdmin.email });
      return created !== undefined;
    },
    async deletePlatformAdmin(email) {
      const [deleted] = await db.delete(authSchema.platformAdmin).where(eq(authSchema.platformAdmin.email, email))
        .returning({ email: authSchema.platformAdmin.email });
      return deleted !== undefined;
    },
  };
}

type SqlAuthValue = string | number | null;

interface SqlAuthDriver {
  database: DatabaseSync | D1DatabaseLike;
  first<T>(query: string, values: SqlAuthValue[]): Promise<T | null>;
  all<T>(query: string, values: SqlAuthValue[]): Promise<T[]>;
  run(query: string, values: SqlAuthValue[]): Promise<number>;
  close?(): Promise<void>;
}

interface RawSession {
  id: string;
  sessionId: string | null;
  createdAt: string | number;
  expiresAt: string | number;
  userAgent: string | null;
}

interface RawModelAlias {
  alias: string;
  upstreamModel: string;
  displayName: string | null;
  enabled: number | boolean;
  createdAt: string | number;
  updatedAt: string | number;
}

interface RawPlatformAdmin {
  email: string;
  createdAt: string | number;
}

export function createSqliteAuthStore(driver: SqlAuthDriver): AuthStore {
  return {
    database: driver.database,
    close: driver.close ? () => driver.close?.() ?? Promise.resolve() : undefined,
    async seedDahliaClient(config) {
      const now = new Date().toISOString();
      const resource = gatewayResource(config);
      const oauthResource = await driver.first<{ id: string }>(
        'SELECT "id" FROM "oauthResource" WHERE "identifier" = ?',
        [resource],
      );
      if (!oauthResource) throw new Error("Dahlia AI Gateway OAuth resource was not created");

      await driver.run(
        `INSERT INTO "oauthClient" (
          "id", "clientId", "disabled", "skipConsent", "scopes", "createdAt", "updatedAt", "name",
          "redirectUris", "tokenEndpointAuthMethod", "applicationType", "grantTypes", "responseTypes", "requirePKCE"
        ) VALUES (?, ?, 0, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT("clientId") DO UPDATE SET
          "disabled" = 0, "skipConsent" = 1, "scopes" = excluded."scopes", "updatedAt" = excluded."updatedAt",
          "name" = excluded."name", "redirectUris" = excluded."redirectUris",
          "tokenEndpointAuthMethod" = excluded."tokenEndpointAuthMethod", "applicationType" = excluded."applicationType",
          "grantTypes" = excluded."grantTypes", "responseTypes" = excluded."responseTypes", "requirePKCE" = 1`,
        [
          "oauth-client-dahlia-macos",
          "dahlia-macos",
          JSON.stringify(OAUTH_SCOPES),
          now,
          now,
          "Dahlia for macOS",
          JSON.stringify(config.oauthRedirectUris),
          "none",
          "native",
          JSON.stringify(["authorization_code", "refresh_token"]),
          JSON.stringify(["code"]),
        ],
      );
      await driver.run(
        `INSERT INTO "oauthClientResource" ("id", "clientId", "resourceId", "createdAt") VALUES (?, ?, ?, ?)
         ON CONFLICT("id") DO UPDATE SET "clientId" = excluded."clientId", "resourceId" = excluded."resourceId"`,
        ["oauth-client-resource-dahlia-macos", "dahlia-macos", resource, now],
      );
    },
    async listDahliaSessions(userId) {
      const rows = await driver.all<RawSession>(
        `SELECT r."id", r."sessionId", r."createdAt", r."expiresAt", s."userAgent"
         FROM "oauthRefreshToken" r LEFT JOIN "session" s ON r."sessionId" = s."id"
         WHERE r."userId" = ? AND r."clientId" = 'dahlia-macos' AND r."revoked" IS NULL AND r."expiresAt" > ?
         ORDER BY r."createdAt" DESC`,
        [userId, new Date().toISOString()],
      );
      return rows.map((row) => ({
        ...row,
        createdAt: new Date(row.createdAt),
        expiresAt: new Date(row.expiresAt),
      }));
    },
    async revokeDahliaSession(userId, refreshTokenId) {
      const changes = await driver.run(
        `UPDATE "oauthRefreshToken" SET "revoked" = ?
         WHERE "id" = ? AND "userId" = ? AND "clientId" = 'dahlia-macos' AND "revoked" IS NULL`,
        [new Date().toISOString(), refreshTokenId, userId],
      );
      if (changes === 0) return false;
      await driver.run('DELETE FROM "oauthAccessToken" WHERE "refreshId" = ?', [refreshTokenId]);
      return true;
    },
    async listModelAliases() {
      const rows = await driver.all<RawModelAlias>(
        'SELECT "alias", "upstreamModel", "displayName", "enabled", "createdAt", "updatedAt" FROM "modelAlias" ORDER BY "alias"',
        [],
      );
      return rows.map((row) => ({
        ...row,
        enabled: Boolean(row.enabled),
        createdAt: new Date(row.createdAt),
        updatedAt: new Date(row.updatedAt),
      }));
    },
    async getEnabledModelAlias(alias) {
      const row = await driver.first<RawModelAlias>(
        'SELECT "alias", "upstreamModel", "displayName", "enabled", "createdAt", "updatedAt" FROM "modelAlias" WHERE "alias" = ? AND "enabled" = 1',
        [alias],
      );
      return row ? {
        ...row,
        enabled: true,
        createdAt: new Date(row.createdAt),
        updatedAt: new Date(row.updatedAt),
      } : null;
    },
    async createModelAlias(input) {
      const now = new Date().toISOString();
      return await driver.run(
        'INSERT INTO "modelAlias" ("alias", "upstreamModel", "displayName", "enabled", "createdAt", "updatedAt") VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT("alias") DO NOTHING',
        [input.alias, input.upstreamModel, input.displayName, input.enabled ? 1 : 0, now, now],
      ) > 0;
    },
    async updateModelAlias(alias, update) {
      return await driver.run(
        'UPDATE "modelAlias" SET "upstreamModel" = ?, "displayName" = ?, "enabled" = ?, "updatedAt" = ? WHERE "alias" = ?',
        [update.upstreamModel, update.displayName, update.enabled ? 1 : 0, new Date().toISOString(), alias],
      ) > 0;
    },
    async deleteModelAlias(alias) {
      return await driver.run('DELETE FROM "modelAlias" WHERE "alias" = ?', [alias]) > 0;
    },
    async listPlatformAdmins() {
      const rows = await driver.all<RawPlatformAdmin>(
        'SELECT "email", "createdAt" FROM "platformAdmin" ORDER BY "email"',
        [],
      );
      return rows.map((row) => ({ ...row, createdAt: new Date(row.createdAt) }));
    },
    async isPlatformAdmin(email) {
      return await driver.first<{ email: string }>(
        'SELECT "email" FROM "platformAdmin" WHERE "email" = ?',
        [email],
      ) !== null;
    },
    async addPlatformAdmin(email) {
      return await driver.run(
        'INSERT INTO "platformAdmin" ("email", "createdAt") VALUES (?, ?) ON CONFLICT("email") DO NOTHING',
        [email, new Date().toISOString()],
      ) > 0;
    },
    async deletePlatformAdmin(email) {
      return await driver.run('DELETE FROM "platformAdmin" WHERE "email" = ?', [email]) > 0;
    },
  };
}

export function createD1AuthStore(database: D1DatabaseLike): AuthStore {
  return createSqliteAuthStore({
    database,
    async first<T>(query: string, values: SqlAuthValue[]) {
      return database.prepare(query).bind(...values).first<T>();
    },
    async all<T>(query: string, values: SqlAuthValue[]) {
      return (await database.prepare(query).bind(...values).all<T>()).results;
    },
    async run(query, values) {
      return (await database.prepare(query).bind(...values).run()).meta.changes;
    },
  });
}
