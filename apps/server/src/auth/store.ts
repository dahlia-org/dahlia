import { EXTERNAL_ORGANIZATION_ID, HEADER_IDENTITY_ISSUER } from "./ids";
import { createAccountSettingsStore, type AccountSettingsStore } from "../account-settings";
import { createSearchSettingsStore, type SearchSettingsStore } from "../search/settings";
import type { DBAdapterInstance } from "better-auth";
import { drizzleAdapter } from "@better-auth/drizzle-adapter/relations-v2";
import { and, asc, desc, eq, gt, inArray, is, isNull, or, sql } from "drizzle-orm";
import { drizzle as drizzleD1, DrizzleD1Database } from "drizzle-orm/d1";
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
  createUnavailableMeetingSyncStore,
} from "../sync/store";
import type { SyncSearchBackend } from "../sync/store";
import type { MeetingSyncStore } from "../sync/types";

const DAHLIA_DESKTOP_CLIENT_ID = "databricks-cli";
const LEGACY_DAHLIA_DESKTOP_CLIENT_ID = "dahlia-macos";
const DAHLIA_DESKTOP_SESSION_CLIENT_IDS = [DAHLIA_DESKTOP_CLIENT_ID, LEGACY_DAHLIA_DESKTOP_CLIENT_ID];
const DEFAULT_ORGANIZATION_NAME = "Default Organization";
const DEFAULT_ORGANIZATION_INITIALIZATION = "default_organization";

function externalOwnerId(metadata: unknown): string | undefined {
  if (typeof metadata !== "string") return undefined;
  try {
    const value = JSON.parse(metadata) as { ownerUserId?: unknown };
    return typeof value.ownerUserId === "string" ? value.ownerUserId : undefined;
  } catch {
    return undefined;
  }
}

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
export interface ServerOrganizationRecord { id: string; name: string; slug: string; memberCount: number; teamCount: number }

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
  batch(statements: D1PreparedStatementLike[]): Promise<unknown[]>;
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
  listAdminUsers(): Promise<AdminUserRecord[]>;
  isAdminUser(userId: string): Promise<boolean>;
  addAdminUser(email: string): Promise<AdminUserRecord | null>;
  removeAdminUser(userId: string): Promise<RemoveAdminResult>;
  getExternalOrganization(userId: string): Promise<OrganizationRecord | null>;
  listExternalOrganizationMembers(userId: string): Promise<OrganizationMemberRecord[] | null>;
  listExternalTeams(userId: string): Promise<TeamRecord[] | null>;
  createExternalTeam(userId: string, name: string): Promise<TeamRecord | null>;
  updateExternalTeam(userId: string, teamId: string, name: string): Promise<TeamRecord | null>;
  deleteExternalTeam(userId: string, teamId: string): Promise<boolean>;
  listExternalTeamMembers(userId: string, teamId: string): Promise<TeamMemberRecord[] | null>;
  addExternalTeamMember(userId: string, teamId: string, memberUserId: string): Promise<boolean>;
  removeExternalTeamMember(userId: string, teamId: string, memberUserId: string): Promise<boolean>;
  deleteVaultPermissionsForPrincipal(
    principalType: "organization" | "team",
    principalId: string,
  ): Promise<void>;
  deleteVaultPermissionsForOrganization(organizationId: string): Promise<void>;
  close?(): Promise<void>;
}

/** @deprecated Use ApplicationStore. */
export type AuthStore = ApplicationStore;

export function createPostgresApplicationStore(
  db: PostgresDatabase,
  searchBackend: SyncSearchBackend = "postgres",
  searchEmbedding?: AppConfig["searchEmbedding"],
  encryption?: AppConfig["encryption"],
): ApplicationStore {
  const externalMembership = async (userId: string) => {
    const [membership] = await db.select({ role: postgresAuthSchema.member.role })
      .from(postgresAuthSchema.member).where(and(
        eq(postgresAuthSchema.member.organizationId, EXTERNAL_ORGANIZATION_ID),
        eq(postgresAuthSchema.member.userId, userId),
      )).limit(1);
    return membership ?? null;
  };
  return {
    database: drizzleAdapter(db, { provider: "pg", schema: postgresAuthSchema, schemaName: "auth" }),
    accountSettings: createAccountSettingsStore(db, true),
    searchSettings: createSearchSettingsStore(db, true),
    sync: createPostgresMeetingSyncStore(db, searchBackend, searchEmbedding, encryption),
    async resolveHeaderUser(identity) {
      const find = async () => {
        const [account] = await db.select({ userId: postgresAuthSchema.account.userId }).from(postgresAuthSchema.account)
          .where(and(eq(postgresAuthSchema.account.issuer, HEADER_IDENTITY_ISSUER), eq(postgresAuthSchema.account.accountId, identity.userId))).limit(1);
        return account?.userId ?? null;
      };
      const existing = await find();
      if (existing) return existing;
      try {
        return await db.transaction(async (tx) => {
          const userId = uuidV7();
          const now = new Date();
          await tx.insert(postgresAuthSchema.user).values({ id: userId, email: identity.email ?? identity.userId,
            name: identity.name ?? identity.email ?? identity.userId, emailVerified: true, role: "user", createdAt: now, updatedAt: now });
          await tx.insert(postgresAuthSchema.account).values({ id: uuidV7(), userId, issuer: HEADER_IDENTITY_ISSUER,
            providerId: "header", accountId: identity.userId, createdAt: now, updatedAt: now });
          return userId;
        });
      } catch (error) {
        if (!isUniqueConstraintError(error)) throw error;
        return find();
      }
    },
    async ensureIdentityUser(identity) {
      const now = new Date();
      const identityUser = () => db.select({
        isInitialUser: sql<boolean>`${postgresAuthSchema.user.id} = (
          select id from ${postgresAuthSchema.user} order by created_at, id limit 1
        )`,
        email: postgresAuthSchema.user.email,
        emailVerified: postgresAuthSchema.user.emailVerified,
        hasAdmin: sql<boolean>`exists (
          select 1 from ${postgresAuthSchema.user} as admins
          where (',' || coalesce(admins.role, 'user') || ',') like '%,admin,%'
        )`,
        hasExternalMembership: sql<boolean>`exists (
          select 1 from ${postgresAuthSchema.member}
          where ${postgresAuthSchema.member.userId} = ${identity.userId}
            and ${postgresAuthSchema.member.organizationId} = ${EXTERNAL_ORGANIZATION_ID}
        )`,
        hasDefaultOrganizationInitialization: sql<boolean>`exists (
          select 1 from ${postgresSchema.serverInitializations}
          where ${postgresSchema.serverInitializations.name} = ${DEFAULT_ORGANIZATION_INITIALIZATION}
        )`,
        hasLegacyExternalOrganization: sql<boolean>`exists (
          select 1 from ${postgresAuthSchema.organization}
          where ${postgresAuthSchema.organization.id} = ${EXTERNAL_ORGANIZATION_ID}
            and ${postgresAuthSchema.organization.name} = 'external'
        )`,
        hasInitializedExternalOrganization: sql<boolean>`exists (
          select 1 from ${postgresAuthSchema.organization}
          where ${postgresAuthSchema.organization.id} = ${EXTERNAL_ORGANIZATION_ID}
            and ${postgresAuthSchema.organization.name} <> 'external'
        )`,
        name: postgresAuthSchema.user.name,
      }).from(postgresAuthSchema.user).where(eq(postgresAuthSchema.user.id, identity.userId)).limit(1);
      let [existing] = await identityUser();
      if (!existing && identity.source === "header") {
        await db.insert(postgresAuthSchema.user).values({
          id: identity.userId,
          name: identity.name ?? identity.email ?? identity.userId,
          email: identity.email ?? identity.userId,
          emailVerified: true,
          role: "user",
          createdAt: now,
          updatedAt: now,
        }).onConflictDoNothing();
        [existing] = await identityUser();
      }
      if (!existing) return false;
      if (identity.source === "header") {
        const email = identity.email ?? identity.userId;
        const name = identity.name ?? email;
        if (existing.email !== email || existing.name !== name || !existing.emailVerified) {
          const [emailOwner] = await db.select({ id: postgresAuthSchema.user.id })
            .from(postgresAuthSchema.user).where(eq(postgresAuthSchema.user.email, email)).limit(1);
          if (emailOwner && emailOwner.id !== identity.userId) return false;
          try {
            await db.update(postgresAuthSchema.user).set({ email, name, emailVerified: true, updatedAt: now })
              .where(eq(postgresAuthSchema.user.id, identity.userId));
          } catch (error) {
            if (isUniqueConstraintError(error)) return false;
            throw error;
          }
        }
      }
      const usesDefaultOrganization = identity.source === "header" || existing.isInitialUser;
      if (existing.hasAdmin && (!usesDefaultOrganization
        || (identity.source === "accounts"
          ? existing.hasDefaultOrganizationInitialization && !existing.hasLegacyExternalOrganization
          : existing.hasInitializedExternalOrganization && existing.hasExternalMembership))) {
        return true;
      }
      await db.execute(sql`
        update ${postgresAuthSchema.user}
        set role = 'admin', updated_at = ${now}
        where id = (select id from ${postgresAuthSchema.user} order by created_at, id limit 1)
          and not exists (
            select 1 from ${postgresAuthSchema.user}
            where (',' || coalesce(role, 'user') || ',') like '%,admin,%'
          )
      `);
      if (usesDefaultOrganization) {
        if (identity.source === "accounts") {
          await db.transaction(async (transaction) => {
            const [initialized] = await transaction.insert(postgresSchema.serverInitializations).values({
              name: DEFAULT_ORGANIZATION_INITIALIZATION, initializedAt: now,
            }).onConflictDoNothing().returning({ name: postgresSchema.serverInitializations.name });
            if (initialized) {
              const [created] = await transaction.insert(postgresAuthSchema.organization).values({
                id: EXTERNAL_ORGANIZATION_ID, name: DEFAULT_ORGANIZATION_NAME, slug: "external",
                createdAt: now, metadata: JSON.stringify({ ownerUserId: identity.userId }),
              }).onConflictDoNothing().returning({ id: postgresAuthSchema.organization.id });
              if (created) {
                await transaction.insert(postgresAuthSchema.member).values({
                  id: uuidV7(), organizationId: created.id, userId: identity.userId, role: "owner", createdAt: now,
                });
              }
            }
            await transaction.update(postgresAuthSchema.organization).set({ name: DEFAULT_ORGANIZATION_NAME }).where(and(
              eq(postgresAuthSchema.organization.id, EXTERNAL_ORGANIZATION_ID),
              eq(postgresAuthSchema.organization.name, "external"),
            ));
          });
          return true;
        }
        const [initialAdmin] = await db.select({ id: postgresAuthSchema.user.id }).from(postgresAuthSchema.user)
          .where(sql`(',' || coalesce(${postgresAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`)
          .orderBy(asc(postgresAuthSchema.user.createdAt), asc(postgresAuthSchema.user.id)).limit(1);
        if (!initialAdmin) return false;
        await db.insert(postgresAuthSchema.organization).values({
          id: EXTERNAL_ORGANIZATION_ID,
          name: DEFAULT_ORGANIZATION_NAME,
          slug: "external",
          createdAt: now,
          metadata: JSON.stringify({ ownerUserId: initialAdmin.id }),
        }).onConflictDoUpdate({
          target: postgresAuthSchema.organization.id,
          set: { name: DEFAULT_ORGANIZATION_NAME },
          setWhere: eq(postgresAuthSchema.organization.name, "external"),
        });
        const [external] = await db.select({ metadata: postgresAuthSchema.organization.metadata })
          .from(postgresAuthSchema.organization)
          .where(eq(postgresAuthSchema.organization.id, EXTERNAL_ORGANIZATION_ID)).limit(1);
        const storedOwnerUserId = externalOwnerId(external?.metadata);
        const ownerUserId = storedOwnerUserId ?? initialAdmin.id;
        if (!storedOwnerUserId) {
          await db.update(postgresAuthSchema.organization)
            .set({ metadata: JSON.stringify({ ownerUserId }) })
            .where(eq(postgresAuthSchema.organization.id, EXTERNAL_ORGANIZATION_ID));
        }
        await db.insert(postgresAuthSchema.member).values({
          id: uuidV7(),
          organizationId: EXTERNAL_ORGANIZATION_ID,
          userId: ownerUserId,
          role: "owner",
          createdAt: now,
        }).onConflictDoUpdate({ target: [postgresAuthSchema.member.organizationId, postgresAuthSchema.member.userId], set: { role: "owner" } });
        const organizationRole = ownerUserId === identity.userId ? "owner" : "member";
        await db.insert(postgresAuthSchema.member).values({
          id: uuidV7(),
          organizationId: EXTERNAL_ORGANIZATION_ID,
          userId: identity.userId,
          role: organizationRole,
          createdAt: now,
        }).onConflictDoUpdate({
          target: [postgresAuthSchema.member.organizationId, postgresAuthSchema.member.userId],
          set: { role: organizationRole },
        });
      }
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
      id: postgresAuthSchema.organization.id, name: postgresAuthSchema.organization.name, slug: postgresAuthSchema.organization.slug,
      memberCount: sql<number>`(select count(*) from ${postgresAuthSchema.member} where ${postgresAuthSchema.member.organizationId} = ${postgresAuthSchema.organization}."id")`.mapWith(Number),
      teamCount: sql<number>`(select count(*) from ${postgresAuthSchema.team} where ${postgresAuthSchema.team.organizationId} = ${postgresAuthSchema.organization}."id")`.mapWith(Number),
    }).from(postgresAuthSchema.organization).orderBy(asc(postgresAuthSchema.organization.name), asc(postgresAuthSchema.organization.id)).limit(limit).offset(offset),
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
        await transaction.execute(sql`select pg_advisory_xact_lock(hashtext('dahlia_admin_mutation'))`);
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
    async getExternalOrganization(userId) {
      const [organization] = await db.select({
        id: postgresAuthSchema.organization.id,
        name: postgresAuthSchema.organization.name,
        slug: postgresAuthSchema.organization.slug,
        role: postgresAuthSchema.member.role,
      }).from(postgresAuthSchema.organization).innerJoin(
        postgresAuthSchema.member,
        and(
          eq(postgresAuthSchema.member.organizationId, postgresAuthSchema.organization.id),
          eq(postgresAuthSchema.member.userId, userId),
        ),
      ).where(eq(postgresAuthSchema.organization.id, EXTERNAL_ORGANIZATION_ID)).limit(1);
      return organization ?? null;
    },
    async listExternalOrganizationMembers(userId) {
      if (!await externalMembership(userId)) return null;
      return db.select({
        id: postgresAuthSchema.member.id,
        userId: postgresAuthSchema.member.userId,
        role: postgresAuthSchema.member.role,
        name: postgresAuthSchema.user.name,
        email: postgresAuthSchema.user.email,
      }).from(postgresAuthSchema.member).innerJoin(
        postgresAuthSchema.user,
        eq(postgresAuthSchema.user.id, postgresAuthSchema.member.userId),
      ).where(eq(postgresAuthSchema.member.organizationId, EXTERNAL_ORGANIZATION_ID))
        .orderBy(asc(postgresAuthSchema.user.name), asc(postgresAuthSchema.user.id));
    },
    async listExternalTeams(userId) {
      if (!await externalMembership(userId)) return null;
      return db.select().from(postgresAuthSchema.team)
        .where(eq(postgresAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID))
        .orderBy(asc(postgresAuthSchema.team.name), asc(postgresAuthSchema.team.id));
    },
    async createExternalTeam(userId, name) {
      if ((await externalMembership(userId))?.role !== "owner") return null;
      const now = new Date();
      const [team] = await db.insert(postgresAuthSchema.team).values({
        id: uuidV7(),
        name,
        organizationId: EXTERNAL_ORGANIZATION_ID,
        createdAt: now,
        updatedAt: now,
      }).returning();
      return team ?? null;
    },
    async updateExternalTeam(userId, teamId, name) {
      if ((await externalMembership(userId))?.role !== "owner") return null;
      const [team] = await db.update(postgresAuthSchema.team).set({ name, updatedAt: new Date() }).where(and(
        eq(postgresAuthSchema.team.id, teamId),
        eq(postgresAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).returning();
      return team ?? null;
    },
    async deleteExternalTeam(userId, teamId) {
      if ((await externalMembership(userId))?.role !== "owner") return false;
      const [target] = await db.select({ id: postgresAuthSchema.team.id }).from(postgresAuthSchema.team).where(and(
        eq(postgresAuthSchema.team.id, teamId),
        eq(postgresAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).limit(1);
      if (!target) return false;
      const [deleted] = await db.delete(postgresAuthSchema.team).where(and(
        eq(postgresAuthSchema.team.id, teamId),
        eq(postgresAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).returning({ id: postgresAuthSchema.team.id });
      if (!deleted) return false;
      await db.delete(postgresSchema.syncedVaultPermission).where(and(
        eq(postgresSchema.syncedVaultPermission.principalType, "team"),
        eq(postgresSchema.syncedVaultPermission.principalId, teamId),
      ));
      return true;
    },
    async listExternalTeamMembers(userId, teamId) {
      if (!await externalMembership(userId)) return null;
      const [team] = await db.select({ id: postgresAuthSchema.team.id }).from(postgresAuthSchema.team).where(and(
        eq(postgresAuthSchema.team.id, teamId),
        eq(postgresAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).limit(1);
      if (!team) return null;
      return db.select({
        id: postgresAuthSchema.teamMember.id,
        userId: postgresAuthSchema.teamMember.userId,
        name: postgresAuthSchema.user.name,
        email: postgresAuthSchema.user.email,
      }).from(postgresAuthSchema.teamMember).innerJoin(
        postgresAuthSchema.user,
        eq(postgresAuthSchema.user.id, postgresAuthSchema.teamMember.userId),
      ).where(eq(postgresAuthSchema.teamMember.teamId, teamId))
        .orderBy(asc(postgresAuthSchema.user.name), asc(postgresAuthSchema.user.id));
    },
    async addExternalTeamMember(userId, teamId, memberUserId) {
      if ((await externalMembership(userId))?.role !== "owner") return false;
      const [candidate] = await db.select({ id: postgresAuthSchema.member.userId }).from(postgresAuthSchema.member)
        .innerJoin(postgresAuthSchema.team, and(
          eq(postgresAuthSchema.team.organizationId, postgresAuthSchema.member.organizationId),
          eq(postgresAuthSchema.team.id, teamId),
        )).where(and(
          eq(postgresAuthSchema.member.organizationId, EXTERNAL_ORGANIZATION_ID),
          eq(postgresAuthSchema.member.userId, memberUserId),
        )).limit(1);
      if (!candidate) return false;
      await db.insert(postgresAuthSchema.teamMember).values({
        id: uuidV7(),
        teamId,
        userId: memberUserId,
        createdAt: new Date(),
      }).onConflictDoNothing();
      await db.update(postgresAuthSchema.team).set({
        memberCount: sql`(select count(*) from ${postgresAuthSchema.teamMember} where ${postgresAuthSchema.teamMember.teamId} = ${teamId})`,
      }).where(eq(postgresAuthSchema.team.id, teamId));
      return true;
    },
    async removeExternalTeamMember(userId, teamId, memberUserId) {
      if ((await externalMembership(userId))?.role !== "owner") return false;
      const [team] = await db.select({ id: postgresAuthSchema.team.id }).from(postgresAuthSchema.team).where(and(
        eq(postgresAuthSchema.team.id, teamId),
        eq(postgresAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).limit(1);
      if (!team) return false;
      const [deleted] = await db.delete(postgresAuthSchema.teamMember).where(and(
        eq(postgresAuthSchema.teamMember.teamId, teamId),
        eq(postgresAuthSchema.teamMember.userId, memberUserId),
      )).returning({ id: postgresAuthSchema.teamMember.id });
      if (!deleted) return false;
      await db.update(postgresAuthSchema.team).set({
        memberCount: sql`(select count(*) from ${postgresAuthSchema.teamMember} where ${postgresAuthSchema.teamMember.teamId} = ${teamId})`,
      }).where(and(
        eq(postgresAuthSchema.team.id, teamId),
        eq(postgresAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      ));
      return true;
    },
    async deleteVaultPermissionsForPrincipal(principalType, principalId) {
      await db.delete(postgresSchema.syncedVaultPermission).where(and(
        eq(postgresSchema.syncedVaultPermission.principalType, principalType),
        eq(postgresSchema.syncedVaultPermission.principalId, principalId),
        eq(postgresSchema.syncedVaultPermission.role, "member"),
      ));
    },
    async deleteVaultPermissionsForOrganization(organizationId) {
      await db.delete(postgresSchema.syncedVaultPermission).where(and(
        eq(postgresSchema.syncedVaultPermission.role, "member"),
        or(
          and(
            eq(postgresSchema.syncedVaultPermission.principalType, "organization"),
            eq(postgresSchema.syncedVaultPermission.principalId, organizationId),
          ),
          and(
            eq(postgresSchema.syncedVaultPermission.principalType, "team"),
            inArray(
              postgresSchema.syncedVaultPermission.principalId,
              db.select({ id: postgresAuthSchema.team.id }).from(postgresAuthSchema.team)
                .where(eq(postgresAuthSchema.team.organizationId, organizationId)),
            ),
          ),
        ),
      ));
    },
  };
}

export function createSqliteApplicationStore(
  db: SQLiteDatabase,
  transactions = false,
  searchEmbedding?: AppConfig["searchEmbedding"],
  encryption?: AppConfig["encryption"],
): ApplicationStore {
  const externalMembership = async (userId: string) => {
    const [membership] = await db.select({ role: sqliteAuthSchema.member.role })
      .from(sqliteAuthSchema.member).where(and(
        eq(sqliteAuthSchema.member.organizationId, EXTERNAL_ORGANIZATION_ID),
        eq(sqliteAuthSchema.member.userId, userId),
      )).limit(1);
    return membership ?? null;
  };
  return {
    database: drizzleAdapter(db, { provider: "sqlite", schema: sqliteAuthSchema, transaction: transactions }),
    accountSettings: createAccountSettingsStore(db, false),
    searchSettings: createSearchSettingsStore(db, false),
    sync: createSqliteMeetingSyncStore(db, searchEmbedding, encryption),
    async resolveHeaderUser(identity) {
      const find = async () => {
        const [account] = await db.select({ userId: sqliteAuthSchema.account.userId }).from(sqliteAuthSchema.account)
          .where(and(eq(sqliteAuthSchema.account.issuer, HEADER_IDENTITY_ISSUER), eq(sqliteAuthSchema.account.accountId, identity.userId))).limit(1);
        return account?.userId ?? null;
      };
      const existing = await find();
      if (existing) return existing;
      try {
        return await db.transaction(async (tx) => {
          const userId = uuidV7();
          const now = new Date();
          await tx.insert(sqliteAuthSchema.user).values({ id: userId, email: identity.email ?? identity.userId,
            name: identity.name ?? identity.email ?? identity.userId, emailVerified: true, role: "user", createdAt: now, updatedAt: now });
          await tx.insert(sqliteAuthSchema.account).values({ id: uuidV7(), userId, issuer: HEADER_IDENTITY_ISSUER,
            providerId: "header", accountId: identity.userId, createdAt: now, updatedAt: now });
          return userId;
        });
      } catch (error) {
        if (!isUniqueConstraintError(error)) throw error;
        return find();
      }
    },
    async ensureIdentityUser(identity) {
      const now = new Date();
      const identityUser = () => db.select({
        isInitialUser: sql<boolean>`${sqliteAuthSchema.user.id} = (
          select id from ${sqliteAuthSchema.user} order by created_at, id limit 1
        )`,
        email: sqliteAuthSchema.user.email,
        emailVerified: sqliteAuthSchema.user.emailVerified,
        hasAdmin: sql<boolean>`exists (
          select 1 from ${sqliteAuthSchema.user} as admins
          where (',' || coalesce(admins.role, 'user') || ',') like '%,admin,%'
        )`,
        hasExternalMembership: sql<boolean>`exists (
          select 1 from ${sqliteAuthSchema.member}
          where ${sqliteAuthSchema.member.userId} = ${identity.userId}
            and ${sqliteAuthSchema.member.organizationId} = ${EXTERNAL_ORGANIZATION_ID}
        )`,
        hasDefaultOrganizationInitialization: sql<boolean>`exists (
          select 1 from ${sqliteSchema.serverInitializations}
          where ${sqliteSchema.serverInitializations.name} = ${DEFAULT_ORGANIZATION_INITIALIZATION}
        )`,
        hasLegacyExternalOrganization: sql<boolean>`exists (
          select 1 from ${sqliteAuthSchema.organization}
          where ${sqliteAuthSchema.organization.id} = ${EXTERNAL_ORGANIZATION_ID}
            and ${sqliteAuthSchema.organization.name} = 'external'
        )`,
        hasInitializedExternalOrganization: sql<boolean>`exists (
          select 1 from ${sqliteAuthSchema.organization}
          where ${sqliteAuthSchema.organization.id} = ${EXTERNAL_ORGANIZATION_ID}
            and ${sqliteAuthSchema.organization.name} <> 'external'
        )`,
        name: sqliteAuthSchema.user.name,
      }).from(sqliteAuthSchema.user).where(eq(sqliteAuthSchema.user.id, identity.userId)).limit(1);
      let [existing] = await identityUser();
      if (!existing && identity.source === "header") {
        await db.insert(sqliteAuthSchema.user).values({
          id: identity.userId,
          name: identity.name ?? identity.email ?? identity.userId,
          email: identity.email ?? identity.userId,
          emailVerified: true,
          role: "user",
          createdAt: now,
          updatedAt: now,
        }).onConflictDoNothing();
        [existing] = await identityUser();
      }
      if (!existing) return false;
      if (identity.source === "header") {
        const email = identity.email ?? identity.userId;
        const name = identity.name ?? email;
        if (existing.email !== email || existing.name !== name || !existing.emailVerified) {
          const [emailOwner] = await db.select({ id: sqliteAuthSchema.user.id })
            .from(sqliteAuthSchema.user).where(eq(sqliteAuthSchema.user.email, email)).limit(1);
          if (emailOwner && emailOwner.id !== identity.userId) return false;
          try {
            await db.update(sqliteAuthSchema.user).set({ email, name, emailVerified: true, updatedAt: now })
              .where(eq(sqliteAuthSchema.user.id, identity.userId));
          } catch (error) {
            if (isUniqueConstraintError(error)) return false;
            throw error;
          }
        }
      }
      const usesDefaultOrganization = identity.source === "header" || existing.isInitialUser;
      if (existing.hasAdmin && (!usesDefaultOrganization
        || (identity.source === "accounts"
          ? existing.hasDefaultOrganizationInitialization && !existing.hasLegacyExternalOrganization
          : existing.hasInitializedExternalOrganization && existing.hasExternalMembership))) {
        return true;
      }
      await db.run(sql`
        update ${sqliteAuthSchema.user}
        set role = 'admin', updated_at = ${now.getTime()}
        where id = (select id from ${sqliteAuthSchema.user} order by created_at, id limit 1)
          and not exists (
            select 1 from ${sqliteAuthSchema.user}
            where (',' || coalesce(role, 'user') || ',') like '%,admin,%'
          )
      `);
      if (usesDefaultOrganization) {
        if (identity.source === "accounts") {
          const initialization = (database: SQLiteDatabase) => [
            database.insert(sqliteSchema.serverInitializations).values({
              name: DEFAULT_ORGANIZATION_INITIALIZATION, initializedAt: now,
            }).onConflictDoNothing(),
            // Keep these inserts adjacent: changes() carries the initialization claim through organization and owner creation.
            database.insert(sqliteAuthSchema.organization).select(database.select({
              id: sql<string>`${EXTERNAL_ORGANIZATION_ID}`.as("id"),
              name: sql<string>`${DEFAULT_ORGANIZATION_NAME}`.as("name"),
              slug: sql<string>`'external'`.as("slug"),
              logo: sql<string | null>`null`.as("logo"),
              createdAt: sql<Date>`${now.getTime()}`.as("created_at"),
              metadata: sql<string>`${JSON.stringify({ ownerUserId: identity.userId })}`.as("metadata"),
            }).from(sqliteSchema.serverInitializations).where(and(
              eq(sqliteSchema.serverInitializations.name, DEFAULT_ORGANIZATION_INITIALIZATION), sql`changes() = 1`,
            ))).onConflictDoNothing(),
            database.insert(sqliteAuthSchema.member).select(database.select({
              id: sql<string>`${uuidV7()}`.as("id"), organizationId: sql<string>`${EXTERNAL_ORGANIZATION_ID}`.as("organization_id"),
              userId: sql<string>`${identity.userId}`.as("user_id"), role: sql<string>`'owner'`.as("role"), createdAt: sql<Date>`${now.getTime()}`.as("created_at"),
            }).from(sqliteAuthSchema.organization).where(and(
              eq(sqliteAuthSchema.organization.id, EXTERNAL_ORGANIZATION_ID), sql`changes() = 1`,
            ))),
            database.update(sqliteAuthSchema.organization).set({ name: DEFAULT_ORGANIZATION_NAME }).where(and(
              eq(sqliteAuthSchema.organization.id, EXTERNAL_ORGANIZATION_ID),
              eq(sqliteAuthSchema.organization.name, "external"),
            )),
          ] as const;
          if (is(db, DrizzleD1Database)) {
            await db.batch(initialization(db));
          } else {
            await db.transaction(async (transaction) => {
              for (const statement of initialization(transaction)) await statement;
            });
          }
          return true;
        }
        const [initialAdmin] = await db.select({ id: sqliteAuthSchema.user.id }).from(sqliteAuthSchema.user)
          .where(sql`(',' || coalesce(${sqliteAuthSchema.user.role}, 'user') || ',') like '%,admin,%'`)
          .orderBy(asc(sqliteAuthSchema.user.createdAt), asc(sqliteAuthSchema.user.id)).limit(1);
        if (!initialAdmin) return false;
        await db.insert(sqliteAuthSchema.organization).values({
          id: EXTERNAL_ORGANIZATION_ID,
          name: DEFAULT_ORGANIZATION_NAME,
          slug: "external",
          createdAt: now,
          metadata: JSON.stringify({ ownerUserId: initialAdmin.id }),
        }).onConflictDoUpdate({
          target: sqliteAuthSchema.organization.id,
          set: { name: DEFAULT_ORGANIZATION_NAME },
          setWhere: eq(sqliteAuthSchema.organization.name, "external"),
        });
        const [external] = await db.select({ metadata: sqliteAuthSchema.organization.metadata })
          .from(sqliteAuthSchema.organization)
          .where(eq(sqliteAuthSchema.organization.id, EXTERNAL_ORGANIZATION_ID)).limit(1);
        const storedOwnerUserId = externalOwnerId(external?.metadata);
        const ownerUserId = storedOwnerUserId ?? initialAdmin.id;
        if (!storedOwnerUserId) {
          await db.update(sqliteAuthSchema.organization)
            .set({ metadata: JSON.stringify({ ownerUserId }) })
            .where(eq(sqliteAuthSchema.organization.id, EXTERNAL_ORGANIZATION_ID));
        }
        await db.insert(sqliteAuthSchema.member).values({
          id: uuidV7(),
          organizationId: EXTERNAL_ORGANIZATION_ID,
          userId: ownerUserId,
          role: "owner",
          createdAt: now,
        }).onConflictDoUpdate({ target: [sqliteAuthSchema.member.organizationId, sqliteAuthSchema.member.userId], set: { role: "owner" } });
        const organizationRole = ownerUserId === identity.userId ? "owner" : "member";
        await db.insert(sqliteAuthSchema.member).values({
          id: uuidV7(),
          organizationId: EXTERNAL_ORGANIZATION_ID,
          userId: identity.userId,
          role: organizationRole,
          createdAt: now,
        }).onConflictDoUpdate({
          target: [sqliteAuthSchema.member.organizationId, sqliteAuthSchema.member.userId],
          set: { role: organizationRole },
        });
      }
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
      id: sqliteAuthSchema.organization.id, name: sqliteAuthSchema.organization.name, slug: sqliteAuthSchema.organization.slug,
      memberCount: sql<number>`(select count(*) from ${sqliteAuthSchema.member} where ${sqliteAuthSchema.member.organizationId} = ${sqliteAuthSchema.organization}."id")`.mapWith(Number),
      teamCount: sql<number>`(select count(*) from ${sqliteAuthSchema.team} where ${sqliteAuthSchema.team.organizationId} = ${sqliteAuthSchema.organization}."id")`.mapWith(Number),
    }).from(sqliteAuthSchema.organization).orderBy(asc(sqliteAuthSchema.organization.name), asc(sqliteAuthSchema.organization.id)).limit(limit).offset(offset),
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
    async getExternalOrganization(userId) {
      const [organization] = await db.select({
        id: sqliteAuthSchema.organization.id,
        name: sqliteAuthSchema.organization.name,
        slug: sqliteAuthSchema.organization.slug,
        role: sqliteAuthSchema.member.role,
      }).from(sqliteAuthSchema.organization).innerJoin(
        sqliteAuthSchema.member,
        and(
          eq(sqliteAuthSchema.member.organizationId, sqliteAuthSchema.organization.id),
          eq(sqliteAuthSchema.member.userId, userId),
        ),
      ).where(eq(sqliteAuthSchema.organization.id, EXTERNAL_ORGANIZATION_ID)).limit(1);
      return organization ?? null;
    },
    async listExternalOrganizationMembers(userId) {
      if (!await externalMembership(userId)) return null;
      return db.select({
        id: sqliteAuthSchema.member.id,
        userId: sqliteAuthSchema.member.userId,
        role: sqliteAuthSchema.member.role,
        name: sqliteAuthSchema.user.name,
        email: sqliteAuthSchema.user.email,
      }).from(sqliteAuthSchema.member).innerJoin(
        sqliteAuthSchema.user,
        eq(sqliteAuthSchema.user.id, sqliteAuthSchema.member.userId),
      ).where(eq(sqliteAuthSchema.member.organizationId, EXTERNAL_ORGANIZATION_ID))
        .orderBy(asc(sqliteAuthSchema.user.name), asc(sqliteAuthSchema.user.id));
    },
    async listExternalTeams(userId) {
      if (!await externalMembership(userId)) return null;
      return db.select().from(sqliteAuthSchema.team)
        .where(eq(sqliteAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID))
        .orderBy(asc(sqliteAuthSchema.team.name), asc(sqliteAuthSchema.team.id));
    },
    async createExternalTeam(userId, name) {
      if ((await externalMembership(userId))?.role !== "owner") return null;
      const now = new Date();
      const [team] = await db.insert(sqliteAuthSchema.team).values({
        id: uuidV7(),
        name,
        organizationId: EXTERNAL_ORGANIZATION_ID,
        createdAt: now,
        updatedAt: now,
      }).returning();
      return team ?? null;
    },
    async updateExternalTeam(userId, teamId, name) {
      if ((await externalMembership(userId))?.role !== "owner") return null;
      const [team] = await db.update(sqliteAuthSchema.team).set({ name, updatedAt: new Date() }).where(and(
        eq(sqliteAuthSchema.team.id, teamId),
        eq(sqliteAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).returning();
      return team ?? null;
    },
    async deleteExternalTeam(userId, teamId) {
      if ((await externalMembership(userId))?.role !== "owner") return false;
      const [target] = await db.select({ id: sqliteAuthSchema.team.id }).from(sqliteAuthSchema.team).where(and(
        eq(sqliteAuthSchema.team.id, teamId),
        eq(sqliteAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).limit(1);
      if (!target) return false;
      const [deleted] = await db.delete(sqliteAuthSchema.team).where(and(
        eq(sqliteAuthSchema.team.id, teamId),
        eq(sqliteAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).returning({ id: sqliteAuthSchema.team.id });
      if (!deleted) return false;
      await db.delete(sqliteSchema.syncedVaultPermission).where(and(
        eq(sqliteSchema.syncedVaultPermission.principalType, "team"),
        eq(sqliteSchema.syncedVaultPermission.principalId, teamId),
      ));
      return true;
    },
    async listExternalTeamMembers(userId, teamId) {
      if (!await externalMembership(userId)) return null;
      const [team] = await db.select({ id: sqliteAuthSchema.team.id }).from(sqliteAuthSchema.team).where(and(
        eq(sqliteAuthSchema.team.id, teamId),
        eq(sqliteAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).limit(1);
      if (!team) return null;
      return db.select({
        id: sqliteAuthSchema.teamMember.id,
        userId: sqliteAuthSchema.teamMember.userId,
        name: sqliteAuthSchema.user.name,
        email: sqliteAuthSchema.user.email,
      }).from(sqliteAuthSchema.teamMember).innerJoin(
        sqliteAuthSchema.user,
        eq(sqliteAuthSchema.user.id, sqliteAuthSchema.teamMember.userId),
      ).where(eq(sqliteAuthSchema.teamMember.teamId, teamId))
        .orderBy(asc(sqliteAuthSchema.user.name), asc(sqliteAuthSchema.user.id));
    },
    async addExternalTeamMember(userId, teamId, memberUserId) {
      if ((await externalMembership(userId))?.role !== "owner") return false;
      const [candidate] = await db.select({ id: sqliteAuthSchema.member.userId }).from(sqliteAuthSchema.member)
        .innerJoin(sqliteAuthSchema.team, and(
          eq(sqliteAuthSchema.team.organizationId, sqliteAuthSchema.member.organizationId),
          eq(sqliteAuthSchema.team.id, teamId),
        )).where(and(
          eq(sqliteAuthSchema.member.organizationId, EXTERNAL_ORGANIZATION_ID),
          eq(sqliteAuthSchema.member.userId, memberUserId),
        )).limit(1);
      if (!candidate) return false;
      await db.insert(sqliteAuthSchema.teamMember).values({
        id: uuidV7(),
        teamId,
        userId: memberUserId,
        createdAt: new Date(),
      }).onConflictDoNothing();
      await db.update(sqliteAuthSchema.team).set({
        memberCount: sql`(select count(*) from ${sqliteAuthSchema.teamMember} where ${sqliteAuthSchema.teamMember.teamId} = ${teamId})`,
      }).where(eq(sqliteAuthSchema.team.id, teamId));
      return true;
    },
    async removeExternalTeamMember(userId, teamId, memberUserId) {
      if ((await externalMembership(userId))?.role !== "owner") return false;
      const [team] = await db.select({ id: sqliteAuthSchema.team.id }).from(sqliteAuthSchema.team).where(and(
        eq(sqliteAuthSchema.team.id, teamId),
        eq(sqliteAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      )).limit(1);
      if (!team) return false;
      const [deleted] = await db.delete(sqliteAuthSchema.teamMember).where(and(
        eq(sqliteAuthSchema.teamMember.teamId, teamId),
        eq(sqliteAuthSchema.teamMember.userId, memberUserId),
      )).returning({ id: sqliteAuthSchema.teamMember.id });
      if (!deleted) return false;
      await db.update(sqliteAuthSchema.team).set({
        memberCount: sql`(select count(*) from ${sqliteAuthSchema.teamMember} where ${sqliteAuthSchema.teamMember.teamId} = ${teamId})`,
      }).where(and(
        eq(sqliteAuthSchema.team.id, teamId),
        eq(sqliteAuthSchema.team.organizationId, EXTERNAL_ORGANIZATION_ID),
      ));
      return true;
    },
    async deleteVaultPermissionsForPrincipal(principalType, principalId) {
      await db.delete(sqliteSchema.syncedVaultPermission).where(and(
        eq(sqliteSchema.syncedVaultPermission.principalType, principalType),
        eq(sqliteSchema.syncedVaultPermission.principalId, principalId),
        eq(sqliteSchema.syncedVaultPermission.role, "member"),
      ));
    },
    async deleteVaultPermissionsForOrganization(organizationId) {
      await db.delete(sqliteSchema.syncedVaultPermission).where(and(
        eq(sqliteSchema.syncedVaultPermission.role, "member"),
        or(
          and(
            eq(sqliteSchema.syncedVaultPermission.principalType, "organization"),
            eq(sqliteSchema.syncedVaultPermission.principalId, organizationId),
          ),
          and(
            eq(sqliteSchema.syncedVaultPermission.principalType, "team"),
            inArray(
              sqliteSchema.syncedVaultPermission.principalId,
              db.select({ id: sqliteAuthSchema.team.id }).from(sqliteAuthSchema.team)
                .where(eq(sqliteAuthSchema.team.organizationId, organizationId)),
            ),
          ),
        ),
      ));
    },
  };
}

export function createD1ApplicationStore(database: D1DatabaseLike): ApplicationStore {
  const store = createSqliteApplicationStore(drizzleD1(database as unknown as D1Database), false, undefined);
  return { ...store, sync: createUnavailableMeetingSyncStore(),
    async resolveHeaderUser(identity) {
      const userId = uuidV7();
      const now = Date.now();
      await database.batch([
        database.prepare(`INSERT INTO user (id, name, email, email_verified, role, created_at, updated_at)
          SELECT ?, ?, ?, 1, 'user', ?, ? WHERE NOT EXISTS (SELECT 1 FROM account WHERE issuer = ? AND account_id = ?)
          ON CONFLICT DO NOTHING`).bind(userId, identity.name ?? identity.email ?? identity.userId,
          identity.email ?? identity.userId, now, now, HEADER_IDENTITY_ISSUER, identity.userId),
        database.prepare(`INSERT INTO account (id, user_id, issuer, provider_id, account_id, created_at, updated_at)
          SELECT ?, id, ?, 'header', ?, ?, ? FROM user WHERE id = ? ON CONFLICT DO NOTHING`)
          .bind(uuidV7(), HEADER_IDENTITY_ISSUER, identity.userId, now, now, userId),
        database.prepare(`DELETE FROM user WHERE id = ? AND NOT EXISTS (SELECT 1 FROM account WHERE user_id = ?)`)
          .bind(userId, userId),
      ]);
      const row = await database.prepare("SELECT user_id FROM account WHERE issuer = ? AND account_id = ?")
        .bind(HEADER_IDENTITY_ISSUER, identity.userId).first<{ user_id: string }>();
      return row?.user_id ?? null;
    },
  };
}

/** @deprecated Use createPostgresApplicationStore. */
export const createPostgresAuthStore = createPostgresApplicationStore;
/** @deprecated Use createSqliteApplicationStore. */
export const createSqliteAuthStore = createSqliteApplicationStore;
/** @deprecated Use createD1ApplicationStore. */
export const createD1AuthStore = createD1ApplicationStore;
