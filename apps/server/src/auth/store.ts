import { headerEmail } from "./header";
import { lockAuthorization } from "./authorization";
import { createOrganizationStore, type OrganizationStore } from "./organizations";
import { HEADER_IDENTITY_ISSUER } from "./ids";
import { createAccountSettingsStore, type AccountSettingsStore } from "../account-settings";
import { createSearchSettingsStore, type SearchSettingsStore } from "../search/settings";
import type { DBAdapterInstance } from "better-auth";
import { drizzleAdapter } from "@better-auth/drizzle-adapter/relations-v2";
import { and, asc, desc, eq, gt, inArray, isNull, sql } from "drizzle-orm";
import { uuidV7 } from "../id";

import { gatewayResource, type AppConfig } from "../config";
import * as postgresSchema from "../db/auth-schema";
import type { PostgresDatabase, SQLiteDatabase } from "../db/client";
import * as postgresAuthSchema from "../db/generated/postgres-auth-schema";
import * as sqliteAuthSchema from "../db/generated/sqlite-auth-schema";
import * as sqliteSchema from "../db/sqlite-schema";
import { OAUTH_SCOPES } from "./scopes";
import type { Identity } from "./identity";
import {
  createPostgresMeetingSyncStore,
  createSqliteMeetingSyncStore,
} from "../sync/store";
import type { SyncSearchBackend } from "../sync/store";
import type { MeetingSyncStore } from "../sync/types";

const DAHLIA_DESKTOP_CLIENT_ID = "databricks-cli";
const LEGACY_DAHLIA_DESKTOP_CLIENT_ID = "dahlia-macos";
const DAHLIA_DESKTOP_SESSION_CLIENT_IDS = [DAHLIA_DESKTOP_CLIENT_ID, LEGACY_DAHLIA_DESKTOP_CLIENT_ID];
function isUniqueConstraintError(error: unknown): boolean {
  const cause = typeof error === "object" && error !== null && "cause" in error
    ? error.cause
    : undefined;
  return [error, cause].some((candidate) => {
    if (typeof candidate !== "object" || candidate === null) return false;
    const details = candidate as { code?: unknown; errcode?: unknown; message?: unknown };
    return details.code === "23505"
      || details.errcode === 2067
      || (typeof details.message === "string" && details.message.includes("UNIQUE constraint failed"));
  });
}

export interface DahliaOAuthSession {
  id: string;
  sessionId: string | null;
  createdAt: Date;
  expiresAt: Date;
  userAgent: string | null;
}

export interface AdminUserRecord {
  id: string;
  name: string;
  email: string;
  createdAt: Date;
}

export interface ServerUserRecord extends AdminUserRecord { role: string | null }
export interface ServerOrganizationRecord { id: string; name: string; slug: string; kind: string; memberCount: number; teamCount: number }

export interface ServerOrganizationDetails {
  id: string; name: string; slug: string; kind: string;
  members: OrganizationMemberRecord[]; teams: { id: string; name: string }[];
}

export type RemoveAdminResult = "removed" | "not_found" | "last_admin";

export interface OrganizationRecord {
  id: string;
  name: string;
  slug: string;
  role: string;
}

export interface OrganizationMemberRecord {
  id: string;
  userId: string;
  role: string;
  name: string;
  email: string;
}

export interface TeamRecord {
  id: string;
  name: string;
  organizationId: string;
  memberCount: number;
  createdAt: Date;
  updatedAt: Date | null;
}

export interface TeamMemberRecord {
  id: string;
  userId: string;
  name: string;
  email: string;
}

export interface ApplicationStore {
  database: DBAdapterInstance;
  accountSettings: AccountSettingsStore;
  searchSettings: SearchSettingsStore;
  sync: MeetingSyncStore;
  resolveHeaderUser(identity: Identity): Promise<string | null>;
  ensureIdentityUser(identity: Identity): Promise<boolean>;
  seedDahliaClient(config: AppConfig): Promise<void>;
  listDahliaSessions(userId: string): Promise<DahliaOAuthSession[]>;
  revokeDahliaSession(userId: string, refreshTokenId: string): Promise<boolean>;
  listServerUsers(limit: number, offset: number): Promise<ServerUserRecord[]>;
  listServerOrganizations(limit: number, offset: number): Promise<ServerOrganizationRecord[]>;
  getServerOrganization(organizationId: string, limit: number, membersOffset: number, teamsOffset: number): Promise<ServerOrganizationDetails | null>;
  listAdminUsers(): Promise<AdminUserRecord[]>;
  isAdminUser(userId: string): Promise<boolean>;
  addAdminUser(email: string): Promise<AdminUserRecord | null>;
  removeAdminUser(userId: string): Promise<RemoveAdminResult>;
  organizations: OrganizationStore;
  close?(): Promise<void>;
}

/** @deprecated Use ApplicationStore. */
export type AuthStore = ApplicationStore;

export function createPostgresApplicationStore(
  db: PostgresDatabase,
  searchBackend: SyncSearchBackend = "postgres",
  searchEmbedding?: AppConfig["searchEmbedding"],
  encryption?: AppConfig["encryption"],
  authProviderId = "external",
): ApplicationStore {
  const organizations = createOrganizationStore(db, true);
  return {
    database: drizzleAdapter(db, { provider: "pg", schema: postgresAuthSchema, schemaName: "auth" }),
    organizations,
    accountSettings: createAccountSettingsStore(db, true),
    searchSettings: createSearchSettingsStore(db, true),
    sync: createPostgresMeetingSyncStore(db, searchBackend, searchEmbedding, encryption),
    async resolveHeaderUser(identity) {
      const email = headerEmail(identity.email ?? identity.userId);
      if (!email) return null;
      const find = async () => {
        const [account] = await db.select({ id: postgresAuthSchema.account.id, userId: postgresAuthSchema.account.userId, providerId: postgresAuthSchema.account.providerId }).from(postgresAuthSchema.account)
          .where(and(eq(postgresAuthSchema.account.issuer, HEADER_IDENTITY_ISSUER), eq(postgresAuthSchema.account.accountId, email))).limit(1);
        if (account && account.providerId !== authProviderId) {
          await db.update(postgresAuthSchema.account).set({ providerId: authProviderId, updatedAt: new Date() })
            .where(eq(postgresAuthSchema.account.id, account.id));
        }
        return account?.userId ?? null;
      };
      const existing = await find();
      if (existing) return existing;
      try {
        return await db.transaction(async (tx) => {
          const userId = uuidV7();
          const now = new Date();
          await tx.insert(postgresAuthSchema.user).values({ id: userId, email,
            name: identity.name ?? identity.email ?? identity.userId, registrationState: "domain", emailVerified: true, role: "user", createdAt: now, updatedAt: now });
          await tx.insert(postgresAuthSchema.account).values({ id: uuidV7(), userId, issuer: HEADER_IDENTITY_ISSUER,
            providerId: authProviderId, accountId: email, createdAt: now, updatedAt: now });
          await createOrganizationStore(tx, true, true).initializeUser(userId);
          return userId;
        });
      } catch (error) {
        if (!isUniqueConstraintError(error)) throw error;
        return find();
      }
    },
    async ensureIdentityUser(identity) {
      await organizations.initializeUser(identity.userId);
      const [existing] = await db.select().from(postgresAuthSchema.user).where(eq(postgresAuthSchema.user.id, identity.userId)).limit(1);
      if (!existing) return false;
      if (identity.source === "header") {
        const email = identity.email ?? existing.email;
        const name = identity.name ?? email;
        if (existing.email !== email || existing.name !== name || !existing.emailVerified) {
          try {
            await db.update(postgresAuthSchema.user).set({ email, name, emailVerified: true, updatedAt: new Date() })
              .where(eq(postgresAuthSchema.user.id, identity.userId));
          } catch (error) { if (isUniqueConstraintError(error)) return false; throw error; }
        }
      }
      await db.update(postgresAuthSchema.user).set({ role: "admin" }).where(and(
        eq(postgresAuthSchema.user.id, identity.userId),
        sql`${postgresAuthSchema.user.id} = (select id from ${postgresAuthSchema.user} order by created_at, id limit 1)`,
        sql`not exists (select 1 from ${postgresAuthSchema.user} where (',' || coalesce(role, 'user') || ',') like '%,admin,%')`,
      ));
      return true;
    },
    async seedDahliaClient(config) {
      const now = new Date();
      await db.insert(postgresSchema.oauthClient).values({
        id: "01990ab0-0000-7000-8000-000000000003",
        clientId: DAHLIA_DESKTOP_CLIENT_ID,
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
      await db.update(postgresSchema.oauthClient).set({ disabled: true, updatedAt: now })
        .where(eq(postgresSchema.oauthClient.clientId, LEGACY_DAHLIA_DESKTOP_CLIENT_ID));
      const resource = gatewayResource(config);
      const [oauthResource] = await db.select({ id: postgresSchema.oauthResource.id })
        .from(postgresSchema.oauthResource)
        .where(eq(postgresSchema.oauthResource.identifier, resource)).limit(1);
      if (!oauthResource) throw new Error("Dahlia AI Gateway OAuth resource was not created");
      await db.insert(postgresSchema.oauthClientResource).values({
        id: "01990ab0-0000-7000-8000-000000000004",
        clientId: DAHLIA_DESKTOP_CLIENT_ID,
        resourceId: resource,
        createdAt: now,
      }).onConflictDoUpdate({
        target: postgresSchema.oauthClientResource.id,
        set: { clientId: DAHLIA_DESKTOP_CLIENT_ID, resourceId: resource },
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
          inArray(postgresSchema.oauthRefreshToken.clientId, DAHLIA_DESKTOP_SESSION_CLIENT_IDS),
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
        inArray(postgresSchema.oauthRefreshToken.clientId, DAHLIA_DESKTOP_SESSION_CLIENT_IDS),
        isNull(postgresSchema.oauthRefreshToken.revoked),
      )).returning({ id: postgresSchema.oauthRefreshToken.id });
      if (!revoked) return false;
      await db.delete(postgresSchema.oauthAccessToken)
        .where(eq(postgresSchema.oauthAccessToken.refreshId, refreshTokenId));
      return true;
    },
    listServerUsers: (limit, offset) => db.select({
      id: postgresAuthSchema.user.id, name: postgresAuthSchema.user.name, email: postgresAuthSchema.user.email,
      role: postgresAuthSchema.user.role, createdAt: postgresAuthSchema.user.createdAt,
    }).from(postgresAuthSchema.user).orderBy(asc(postgresAuthSchema.user.email), asc(postgresAuthSchema.user.id)).limit(limit).offset(offset),
    listServerOrganizations: (limit, offset) => db.select({
      id: postgresAuthSchema.organization.id, name: postgresAuthSchema.organization.name, slug: postgresAuthSchema.organization.slug, kind: postgresAuthSchema.organization.kind,
      memberCount: sql<number>`(select count(*) from ${postgresAuthSchema.member} where ${postgresAuthSchema.member.organizationId} = ${postgresAuthSchema.organization}."id")`.mapWith(Number),
      teamCount: sql<number>`(select count(*) from ${postgresAuthSchema.team} where ${postgresAuthSchema.team.organizationId} = ${postgresAuthSchema.organization}."id")`.mapWith(Number),
    }).from(postgresAuthSchema.organization).orderBy(asc(postgresAuthSchema.organization.name), asc(postgresAuthSchema.organization.id)).limit(limit).offset(offset),
    async getServerOrganization(organizationId, limit, membersOffset, teamsOffset) {
      const [organization] = await db.select({ id: postgresAuthSchema.organization.id, name: postgresAuthSchema.organization.name, slug: postgresAuthSchema.organization.slug, kind: postgresAuthSchema.organization.kind })
        .from(postgresAuthSchema.organization).where(eq(postgresAuthSchema.organization.id, organizationId)).limit(1);
      if (!organization) return null;
      const members = await db.select({ id: postgresAuthSchema.member.id, userId: postgresAuthSchema.user.id, role: postgresAuthSchema.member.role,
        name: postgresAuthSchema.user.name, email: postgresAuthSchema.user.email })
        .from(postgresAuthSchema.member).innerJoin(postgresAuthSchema.user, eq(postgresAuthSchema.member.userId, postgresAuthSchema.user.id))
        .where(eq(postgresAuthSchema.member.organizationId, organizationId))
        .orderBy(asc(postgresAuthSchema.user.name), asc(postgresAuthSchema.member.id)).limit(limit).offset(membersOffset);
      const teams = await db.select({ id: postgresAuthSchema.team.id, name: postgresAuthSchema.team.name })
        .from(postgresAuthSchema.team).where(eq(postgresAuthSchema.team.organizationId, organizationId))
        .orderBy(asc(postgresAuthSchema.team.name), asc(postgresAuthSchema.team.id)).limit(limit).offset(teamsOffset);
      return { ...organization, members, teams };
    },
    listAdminUsers: () => db.select({
      id: postgresAuthSchema.user.id,
      name: postgresAuthSchema.user.name,
      email: postgresAuthSchema.user.email,
      createdAt: postgresAuthSchema.user.createdAt,
    }).from(postgresAuthSchema.user)
      .where(sql`(',' || coalesce(${postgresAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`)
      .orderBy(asc(postgresAuthSchema.user.email)),
    async isAdminUser(userId) {
      const [row] = await db.select({ id: postgresAuthSchema.user.id }).from(postgresAuthSchema.user)
        .where(and(
          eq(postgresAuthSchema.user.id, userId),
          sql`(',' || coalesce(${postgresAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`,
        )).limit(1);
      return row !== undefined;
    },
    async addAdminUser(email) {
      const [updated] = await db.update(postgresAuthSchema.user).set({ role: "admin", updatedAt: new Date() })
        .where(eq(postgresAuthSchema.user.email, email)).returning({
          id: postgresAuthSchema.user.id,
          name: postgresAuthSchema.user.name,
          email: postgresAuthSchema.user.email,
          createdAt: postgresAuthSchema.user.createdAt,
        });
      return updated ?? null;
    },
    async removeAdminUser(userId) {
      return db.transaction(async (transaction) => {
        await lockAuthorization(transaction, postgresSchema, true);
        const [updated] = await transaction.update(postgresAuthSchema.user)
          .set({ role: "user", updatedAt: new Date() })
          .where(and(
            eq(postgresAuthSchema.user.id, userId),
            sql`(',' || coalesce(${postgresAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`,
            sql`(select count(*) from ${postgresAuthSchema.user} as admins where (',' || coalesce(admins.role, 'user') || ',') like '%,admin,%') > 1`,
          )).returning({ id: postgresAuthSchema.user.id });
        if (updated) return "removed";
        const [admin] = await transaction.select({ id: postgresAuthSchema.user.id })
          .from(postgresAuthSchema.user).where(and(
            eq(postgresAuthSchema.user.id, userId),
            sql`(',' || coalesce(${postgresAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`,
          )).limit(1);
        return admin ? "last_admin" : "not_found";
      });
    },

  };
}

export function createSqliteApplicationStore(
  db: SQLiteDatabase,
  transactions = false,
  searchEmbedding?: AppConfig["searchEmbedding"],
  encryption?: AppConfig["encryption"],
  authProviderId = "external",
): ApplicationStore {
  const organizations = createOrganizationStore(db, false);
  return {
    database: drizzleAdapter(db, { provider: "sqlite", schema: sqliteAuthSchema, transaction: transactions }),
    organizations,
    accountSettings: createAccountSettingsStore(db, false),
    searchSettings: createSearchSettingsStore(db, false),
    sync: createSqliteMeetingSyncStore(db, searchEmbedding, encryption),
    async resolveHeaderUser(identity) {
      const email = headerEmail(identity.email ?? identity.userId);
      if (!email) return null;
      const find = async () => {
        const [account] = await db.select({ id: sqliteAuthSchema.account.id, userId: sqliteAuthSchema.account.userId, providerId: sqliteAuthSchema.account.providerId }).from(sqliteAuthSchema.account)
          .where(and(eq(sqliteAuthSchema.account.issuer, HEADER_IDENTITY_ISSUER), eq(sqliteAuthSchema.account.accountId, email))).limit(1);
        if (account && account.providerId !== authProviderId) {
          await db.update(sqliteAuthSchema.account).set({ providerId: authProviderId, updatedAt: new Date() })
            .where(eq(sqliteAuthSchema.account.id, account.id));
        }
        return account?.userId ?? null;
      };
      const existing = await find();
      if (existing) return existing;
      try {
        return await db.transaction(async (tx) => {
          const userId = uuidV7();
          const now = new Date();
          await tx.insert(sqliteAuthSchema.user).values({ id: userId, email,
            name: identity.name ?? identity.email ?? identity.userId, registrationState: "domain", emailVerified: true, role: "user", createdAt: now, updatedAt: now });
          await tx.insert(sqliteAuthSchema.account).values({ id: uuidV7(), userId, issuer: HEADER_IDENTITY_ISSUER,
            providerId: authProviderId, accountId: email, createdAt: now, updatedAt: now });
          await createOrganizationStore(tx, false, true).initializeUser(userId);
          return userId;
        });
      } catch (error) {
        if (!isUniqueConstraintError(error)) throw error;
        return find();
      }
    },
    async ensureIdentityUser(identity) {
      await organizations.initializeUser(identity.userId);
      const [existing] = await db.select().from(sqliteAuthSchema.user).where(eq(sqliteAuthSchema.user.id, identity.userId)).limit(1);
      if (!existing) return false;
      if (identity.source === "header") {
        const email = identity.email ?? existing.email;
        const name = identity.name ?? email;
        if (existing.email !== email || existing.name !== name || !existing.emailVerified) {
          try {
            await db.update(sqliteAuthSchema.user).set({ email, name, emailVerified: true, updatedAt: new Date() })
              .where(eq(sqliteAuthSchema.user.id, identity.userId));
          } catch (error) { if (isUniqueConstraintError(error)) return false; throw error; }
        }
      }
      await db.update(sqliteAuthSchema.user).set({ role: "admin" }).where(and(
        eq(sqliteAuthSchema.user.id, identity.userId),
        sql`${sqliteAuthSchema.user.id} = (select id from ${sqliteAuthSchema.user} order by created_at, id limit 1)`,
        sql`not exists (select 1 from ${sqliteAuthSchema.user} where (',' || coalesce(role, 'user') || ',') like '%,admin,%')`,
      ));
      return true;
    },
    async seedDahliaClient(config) {
      const now = new Date();
      await db.insert(sqliteSchema.oauthClient).values({
        id: "01990ab0-0000-7000-8000-000000000003",
        clientId: DAHLIA_DESKTOP_CLIENT_ID,
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
      await db.update(sqliteSchema.oauthClient).set({ disabled: true, updatedAt: now })
        .where(eq(sqliteSchema.oauthClient.clientId, LEGACY_DAHLIA_DESKTOP_CLIENT_ID));
      const resource = gatewayResource(config);
      const [oauthResource] = await db.select({ id: sqliteSchema.oauthResource.id })
        .from(sqliteSchema.oauthResource)
        .where(eq(sqliteSchema.oauthResource.identifier, resource)).limit(1);
      if (!oauthResource) throw new Error("Dahlia AI Gateway OAuth resource was not created");
      await db.insert(sqliteSchema.oauthClientResource).values({
        id: "01990ab0-0000-7000-8000-000000000004",
        clientId: DAHLIA_DESKTOP_CLIENT_ID,
        resourceId: resource,
        createdAt: now,
      }).onConflictDoUpdate({
        target: sqliteSchema.oauthClientResource.id,
        set: { clientId: DAHLIA_DESKTOP_CLIENT_ID, resourceId: resource },
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
          inArray(sqliteSchema.oauthRefreshToken.clientId, DAHLIA_DESKTOP_SESSION_CLIENT_IDS),
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
        inArray(sqliteSchema.oauthRefreshToken.clientId, DAHLIA_DESKTOP_SESSION_CLIENT_IDS),
        isNull(sqliteSchema.oauthRefreshToken.revoked),
      )).returning({ id: sqliteSchema.oauthRefreshToken.id });
      if (!revoked) return false;
      await db.delete(sqliteSchema.oauthAccessToken).where(eq(sqliteSchema.oauthAccessToken.refreshId, refreshTokenId));
      return true;
    },
    listServerUsers: (limit, offset) => db.select({
      id: sqliteAuthSchema.user.id, name: sqliteAuthSchema.user.name, email: sqliteAuthSchema.user.email,
      role: sqliteAuthSchema.user.role, createdAt: sqliteAuthSchema.user.createdAt,
    }).from(sqliteAuthSchema.user).orderBy(asc(sqliteAuthSchema.user.email), asc(sqliteAuthSchema.user.id)).limit(limit).offset(offset),
    listServerOrganizations: (limit, offset) => db.select({
      id: sqliteAuthSchema.organization.id, name: sqliteAuthSchema.organization.name, slug: sqliteAuthSchema.organization.slug, kind: sqliteAuthSchema.organization.kind,
      memberCount: sql<number>`(select count(*) from ${sqliteAuthSchema.member} where ${sqliteAuthSchema.member.organizationId} = ${sqliteAuthSchema.organization}."id")`.mapWith(Number),
      teamCount: sql<number>`(select count(*) from ${sqliteAuthSchema.team} where ${sqliteAuthSchema.team.organizationId} = ${sqliteAuthSchema.organization}."id")`.mapWith(Number),
    }).from(sqliteAuthSchema.organization).orderBy(asc(sqliteAuthSchema.organization.name), asc(sqliteAuthSchema.organization.id)).limit(limit).offset(offset),
    async getServerOrganization(organizationId, limit, membersOffset, teamsOffset) {
      const [organization] = await db.select({ id: sqliteAuthSchema.organization.id, name: sqliteAuthSchema.organization.name, slug: sqliteAuthSchema.organization.slug, kind: sqliteAuthSchema.organization.kind })
        .from(sqliteAuthSchema.organization).where(eq(sqliteAuthSchema.organization.id, organizationId)).limit(1);
      if (!organization) return null;
      const members = await db.select({ id: sqliteAuthSchema.member.id, userId: sqliteAuthSchema.user.id, role: sqliteAuthSchema.member.role,
        name: sqliteAuthSchema.user.name, email: sqliteAuthSchema.user.email })
        .from(sqliteAuthSchema.member).innerJoin(sqliteAuthSchema.user, eq(sqliteAuthSchema.member.userId, sqliteAuthSchema.user.id))
        .where(eq(sqliteAuthSchema.member.organizationId, organizationId))
        .orderBy(asc(sqliteAuthSchema.user.name), asc(sqliteAuthSchema.member.id)).limit(limit).offset(membersOffset);
      const teams = await db.select({ id: sqliteAuthSchema.team.id, name: sqliteAuthSchema.team.name })
        .from(sqliteAuthSchema.team).where(eq(sqliteAuthSchema.team.organizationId, organizationId))
        .orderBy(asc(sqliteAuthSchema.team.name), asc(sqliteAuthSchema.team.id)).limit(limit).offset(teamsOffset);
      return { ...organization, members, teams };
    },
    listAdminUsers: () => db.select({
      id: sqliteAuthSchema.user.id,
      name: sqliteAuthSchema.user.name,
      email: sqliteAuthSchema.user.email,
      createdAt: sqliteAuthSchema.user.createdAt,
    }).from(sqliteAuthSchema.user)
      .where(sql`(',' || coalesce(${sqliteAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`)
      .orderBy(asc(sqliteAuthSchema.user.email)),
    async isAdminUser(userId) {
      const [row] = await db.select({ id: sqliteAuthSchema.user.id }).from(sqliteAuthSchema.user)
        .where(and(
          eq(sqliteAuthSchema.user.id, userId),
          sql`(',' || coalesce(${sqliteAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`,
        )).limit(1);
      return row !== undefined;
    },
    async addAdminUser(email) {
      const [updated] = await db.update(sqliteAuthSchema.user).set({ role: "admin", updatedAt: new Date() })
        .where(eq(sqliteAuthSchema.user.email, email)).returning({
          id: sqliteAuthSchema.user.id,
          name: sqliteAuthSchema.user.name,
          email: sqliteAuthSchema.user.email,
          createdAt: sqliteAuthSchema.user.createdAt,
        });
      return updated ?? null;
    },
    async removeAdminUser(userId) {
      const [updated] = await db.update(sqliteAuthSchema.user).set({ role: "user", updatedAt: new Date() })
        .where(and(
          eq(sqliteAuthSchema.user.id, userId),
          sql`(',' || coalesce(${sqliteAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`,
          sql`(select count(*) from ${sqliteAuthSchema.user} as admins where (',' || coalesce(admins.role, 'user') || ',') like '%,admin,%') > 1`,
        )).returning({ id: sqliteAuthSchema.user.id });
      if (updated) return "removed";
      const [admin] = await db.select({ id: sqliteAuthSchema.user.id }).from(sqliteAuthSchema.user).where(and(
        eq(sqliteAuthSchema.user.id, userId),
        sql`(',' || coalesce(${sqliteAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`,
      )).limit(1);
      return admin ? "last_admin" : "not_found";
    },

  };
}

/** @deprecated Use createPostgresApplicationStore. */
export const createPostgresAuthStore = createPostgresApplicationStore;
/** @deprecated Use createSqliteApplicationStore. */
export const createSqliteAuthStore = createSqliteApplicationStore;
