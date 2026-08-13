import type { DatabaseSync } from "node:sqlite";

import type { DBAdapterInstance } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { and, asc, desc, eq, gt, isNull, lt, ne, or, sql } from "drizzle-orm";

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

export interface BillingSubscriptionRecord {
  plan: string;
  status: string;
  stripeCustomerId: string | null;
  periodStart: Date | null;
  periodEnd: Date | null;
  cancelAtPeriodEnd: boolean;
  cancelAt: Date | null;
  canceledAt: Date | null;
  endedAt: Date | null;
}

export interface GatewayEntitlementRecord {
  plan: string;
  status: string;
  periodEnd: Date | null;
  cancelAtPeriodEnd: boolean;
  cancelAt: Date | null;
  canceledAt: Date | null;
  endedAt: Date | null;
}

export interface GatewayEntitlementUpdate extends GatewayEntitlementRecord {
  referenceId: string;
  stripeSubscriptionId: string;
  eventCreated: number;
  eventId: string;
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

export interface AuthStore {
  database: DBAdapterInstance | DatabaseSync | D1Database;
  seedDahliaClient(config: AppConfig): Promise<void>;
  listDahliaSessions(userId: string): Promise<DahliaOAuthSession[]>;
  revokeDahliaSession(userId: string, refreshTokenId: string): Promise<boolean>;
  getBillingSubscription(userId: string): Promise<BillingSubscriptionRecord | null>;
  getStripeCustomerId(userId: string): Promise<string | null>;
  getBillingReferenceId(stripeSubscriptionId: string): Promise<string | null>;
  getGatewayEntitlement(userId: string): Promise<GatewayEntitlementRecord | null>;
  syncGatewayEntitlement(update: GatewayEntitlementUpdate): Promise<"stale" | "updated">;
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
    async getBillingSubscription(userId) {
      const [subscription] = await db
        .select({
          plan: authSchema.subscription.plan,
          status: authSchema.subscription.status,
          stripeCustomerId: authSchema.subscription.stripeCustomerId,
          periodStart: authSchema.subscription.periodStart,
          periodEnd: authSchema.subscription.periodEnd,
          cancelAtPeriodEnd: authSchema.subscription.cancelAtPeriodEnd,
          cancelAt: authSchema.subscription.cancelAt,
          canceledAt: authSchema.subscription.canceledAt,
          endedAt: authSchema.subscription.endedAt,
        })
        .from(authSchema.subscription)
        .where(eq(authSchema.subscription.referenceId, userId))
        .orderBy(
          sql`${authSchema.subscription.periodEnd} DESC NULLS LAST`,
          sql`${authSchema.subscription.periodStart} DESC NULLS LAST`,
        )
        .limit(1);
      if (!subscription) return null;
      return {
        ...subscription,
        status: subscription.status ?? "incomplete",
        cancelAtPeriodEnd: subscription.cancelAtPeriodEnd ?? false,
      };
    },
    async getStripeCustomerId(userId) {
      const [row] = await db
        .select({ stripeCustomerId: authSchema.user.stripeCustomerId })
        .from(authSchema.user)
        .where(eq(authSchema.user.id, userId))
        .limit(1);
      return row?.stripeCustomerId ?? null;
    },
    async getBillingReferenceId(stripeSubscriptionId) {
      const [row] = await db
        .select({ referenceId: authSchema.subscription.referenceId })
        .from(authSchema.subscription)
        .where(eq(authSchema.subscription.stripeSubscriptionId, stripeSubscriptionId))
        .limit(1);
      return row?.referenceId ?? null;
    },
    async getGatewayEntitlement(userId) {
      const [row] = await db
        .select({
          plan: authSchema.gatewayEntitlement.plan,
          status: authSchema.gatewayEntitlement.status,
          periodEnd: authSchema.gatewayEntitlement.periodEnd,
          cancelAtPeriodEnd: authSchema.gatewayEntitlement.cancelAtPeriodEnd,
          cancelAt: authSchema.gatewayEntitlement.cancelAt,
          canceledAt: authSchema.gatewayEntitlement.canceledAt,
          endedAt: authSchema.gatewayEntitlement.endedAt,
        })
        .from(authSchema.gatewayEntitlement)
        .where(eq(authSchema.gatewayEntitlement.referenceId, userId))
        .limit(1);
      return row ?? null;
    },
    async syncGatewayEntitlement(update) {
      const incomingDeniesAccess = update.status !== "active" && update.status !== "trialing";
      const [updated] = await db
        .insert(authSchema.gatewayEntitlement)
        .values(update)
        .onConflictDoUpdate({
          target: authSchema.gatewayEntitlement.referenceId,
          set: update,
          setWhere: or(
            lt(authSchema.gatewayEntitlement.eventCreated, update.eventCreated),
            ...(incomingDeniesAccess
              ? [and(
                  eq(authSchema.gatewayEntitlement.eventCreated, update.eventCreated),
                  ne(authSchema.gatewayEntitlement.eventId, update.eventId),
                )]
              : []),
          ),
        })
        .returning({ referenceId: authSchema.gatewayEntitlement.referenceId });
      return updated ? "updated" : "stale";
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
  database: DatabaseSync | D1Database;
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

interface RawBillingSubscription {
  plan: string;
  status: string | null;
  stripeCustomerId: string | null;
  periodStart: string | number | null;
  periodEnd: string | number | null;
  cancelAtPeriodEnd: number | boolean | null;
  cancelAt: string | number | null;
  canceledAt: string | number | null;
  endedAt: string | number | null;
}

interface RawGatewayEntitlement {
  plan: string;
  status: string;
  periodEnd: string | number | null;
  cancelAtPeriodEnd: number | boolean;
  cancelAt: string | number | null;
  canceledAt: string | number | null;
  endedAt: string | number | null;
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

function date(value: string | number | null): Date | null {
  return value === null ? null : new Date(value);
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
    async getBillingSubscription(userId) {
      const row = await driver.first<RawBillingSubscription>(
        `SELECT "plan", "status", "stripeCustomerId", "periodStart", "periodEnd",
                "cancelAtPeriodEnd", "cancelAt", "canceledAt", "endedAt"
         FROM "subscription" WHERE "referenceId" = ?
         ORDER BY COALESCE("periodEnd", "endedAt", "canceledAt", "periodStart") DESC LIMIT 1`,
        [userId],
      );
      if (!row) return null;
      return {
        plan: row.plan,
        status: row.status ?? "incomplete",
        stripeCustomerId: row.stripeCustomerId,
        periodStart: date(row.periodStart),
        periodEnd: date(row.periodEnd),
        cancelAtPeriodEnd: Boolean(row.cancelAtPeriodEnd),
        cancelAt: date(row.cancelAt),
        canceledAt: date(row.canceledAt),
        endedAt: date(row.endedAt),
      };
    },
    async getStripeCustomerId(userId) {
      const row = await driver.first<{ stripeCustomerId: string | null }>(
        'SELECT "stripeCustomerId" FROM "user" WHERE "id" = ?',
        [userId],
      );
      return row?.stripeCustomerId ?? null;
    },
    async getBillingReferenceId(stripeSubscriptionId) {
      const row = await driver.first<{ referenceId: string }>(
        'SELECT "referenceId" FROM "subscription" WHERE "stripeSubscriptionId" = ? LIMIT 1',
        [stripeSubscriptionId],
      );
      return row?.referenceId ?? null;
    },
    async getGatewayEntitlement(userId) {
      const row = await driver.first<RawGatewayEntitlement>(
        `SELECT "plan", "status", "periodEnd", "cancelAtPeriodEnd", "cancelAt", "canceledAt", "endedAt"
         FROM "gatewayEntitlement" WHERE "referenceId" = ?`,
        [userId],
      );
      return row ? {
        ...row,
        periodEnd: date(row.periodEnd),
        cancelAtPeriodEnd: Boolean(row.cancelAtPeriodEnd),
        cancelAt: date(row.cancelAt),
        canceledAt: date(row.canceledAt),
        endedAt: date(row.endedAt),
      } : null;
    },
    async syncGatewayEntitlement(update) {
      const changes = await driver.run(
        `INSERT INTO "gatewayEntitlement" (
          "referenceId", "stripeSubscriptionId", "plan", "status", "periodEnd", "cancelAtPeriodEnd",
          "cancelAt", "canceledAt", "endedAt", "eventCreated", "eventId"
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT("referenceId") DO UPDATE SET
          "stripeSubscriptionId" = excluded."stripeSubscriptionId",
          "plan" = excluded."plan",
          "status" = excluded."status",
          "periodEnd" = excluded."periodEnd",
          "cancelAtPeriodEnd" = excluded."cancelAtPeriodEnd",
          "cancelAt" = excluded."cancelAt",
          "canceledAt" = excluded."canceledAt",
          "endedAt" = excluded."endedAt",
          "eventCreated" = excluded."eventCreated",
          "eventId" = excluded."eventId"
        WHERE "gatewayEntitlement"."eventCreated" < excluded."eventCreated"
          OR ("gatewayEntitlement"."eventCreated" = excluded."eventCreated"
            AND "gatewayEntitlement"."eventId" <> excluded."eventId"
            AND excluded."status" NOT IN ('active', 'trialing'))`,
        [
          update.referenceId,
          update.stripeSubscriptionId,
          update.plan,
          update.status,
          update.periodEnd?.toISOString() ?? null,
          update.cancelAtPeriodEnd ? 1 : 0,
          update.cancelAt?.toISOString() ?? null,
          update.canceledAt?.toISOString() ?? null,
          update.endedAt?.toISOString() ?? null,
          update.eventCreated,
          update.eventId,
        ],
      );
      return changes > 0 ? "updated" : "stale";
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

export function createD1AuthStore(database: D1Database): AuthStore {
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
