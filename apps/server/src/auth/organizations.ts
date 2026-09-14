import { and, eq, inArray, or, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { drizzleAdapter } from "@better-auth/drizzle-adapter/relations-v2";
import type { DBAdapterInstance } from "better-auth";
import type { SQLiteDatabase } from "../db/client";
import * as postgres from "../db/auth-schema";
import * as sqlite from "../db/sqlite-schema";
import * as postgresAuth from "../db/generated/postgres-auth-schema";
import * as sqliteAuth from "../db/generated/sqlite-auth-schema";
import { uuidV7 } from "../id";
import { HEADER_IDENTITY_ISSUER } from "./ids";
import { APIError } from "better-auth/api";
import type { Identity } from "./identity";
import { autoJoinDomainsSchema, isSharedEmailDomain, type AutoJoinDomains } from "./auto-join-domains";
import { headerEmail } from "./header";
import { authorizationConflict, lockAuthorization, readAuthorization, validateAuthorization } from "./authorization";

export interface OrganizationStore {
  getAutoJoinDomains(identity: Identity, organizationId: string): Promise<AutoJoinDomains>;
  updateAutoJoinDomains(identity: Identity, organizationId: string, input: unknown): Promise<AutoJoinDomains>;
  initializeUser(userId: string, headerProviderId?: string): Promise<void>;
  transaction<T>(action: (database: DBAdapterInstance, organizations: OrganizationStore) => Promise<T>): Promise<T>;
  addTeamCreator(teamId: string, userId: string): Promise<void>;
  assertTeamOrganization(organizationId: string): Promise<void>;
}

export function createOrganizationStore(connection: NodePgDatabase | SQLiteDatabase, isPostgres: boolean, inTransaction = false): OrganizationStore {
  const db = connection as NodePgDatabase;
  const schema = isPostgres ? postgres : sqlite as unknown as typeof postgres;
  const transaction = async <T>(action: (tx: NodePgDatabase) => Promise<T>) => inTransaction ? action(db) : db.transaction(action);
  async function assertAccess(tx: NodePgDatabase, identity: Identity, organizationId: string, write: boolean) {
    const [membership] = await tx.select({ role: schema.member.role, kind: schema.organization.kind }).from(schema.member)
      .innerJoin(schema.organization, eq(schema.organization.id, schema.member.organizationId))
      .where(and(eq(schema.member.userId, identity.userId), eq(schema.member.organizationId, organizationId)));
    if (!membership || (write && (identity.impersonated || !["owner", "admin"].includes(membership.role)))) {
      throw new APIError("FORBIDDEN", { code: "organization_access_denied" });
    }
    if (write && membership.kind !== "team") authorizationConflict("personal_organization_immutable");
  }
  return {
    async getAutoJoinDomains(identity, organizationId) {
      return transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        await assertAccess(tx, identity, organizationId, false);
        const rows = await tx.select({ domain: schema.organizationAutoJoinDomain.domain }).from(schema.organizationAutoJoinDomain)
          .where(eq(schema.organizationAutoJoinDomain.organizationId, organizationId)).orderBy(schema.organizationAutoJoinDomain.domain);
        return { domains: rows.map(({ domain }) => domain) };
      });
    },
    async updateAutoJoinDomains(identity, organizationId, input) {
      return transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        await assertAccess(tx, identity, organizationId, true);
        const parsed = autoJoinDomainsSchema.safeParse(input);
        if (!parsed.success) throw new APIError("BAD_REQUEST", { code: "invalid_auto_join_domain" });
        const domains = [...new Set(parsed.data.domains)].sort();
        if (domains.some(isSharedEmailDomain)) throw new APIError("BAD_REQUEST", { code: "shared_email_domain" });
        if (domains.length) {
          const existing = await tx.select().from(schema.organizationAutoJoinDomain).where(inArray(schema.organizationAutoJoinDomain.domain, domains));
          if (existing.some((row) => row.organizationId !== organizationId)) authorizationConflict("auto_join_domain_in_use");
        }
        await tx.delete(schema.organizationAutoJoinDomain).where(eq(schema.organizationAutoJoinDomain.organizationId, organizationId));
        if (domains.length) await tx.insert(schema.organizationAutoJoinDomain).values(domains.map((domain) => ({ domain, organizationId })));
        return { domains };
      });
    },
    async initializeUser(userId, headerProviderId) {
      await transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        if (isPostgres) await tx.execute(sql`select set_config('app.user_id', ${userId}, true)`);
        const [user] = await tx.select().from(schema.user).where(eq(schema.user.id, userId));
        if (!user || user.registrationState === "ready") return;
        if (headerProviderId !== undefined) {
          const email = headerEmail(user.email);
          if (!email) return authorizationConflict("invalid_header_email");
          await tx.insert(schema.account).values({ id: uuidV7(), userId, issuer: HEADER_IDENTITY_ISSUER,
            providerId: headerProviderId, accountId: email, createdAt: user.createdAt, updatedAt: user.updatedAt });
        }
        const availableSlug = async (source: string) => {
          const base = source.toLowerCase().replace(/[^a-z0-9]/gu, "_") || "organization";
          const pattern = `${base.replaceAll("_", "!_")}!_%`;
          const existing = await tx.select({ slug: schema.organization.slug }).from(schema.organization)
            .where(or(eq(schema.organization.slug, base), sql`${schema.organization.slug} like ${pattern} escape '!'`));
          const occupied = new Set(existing.map(({ slug }) => slug));
          let slug = base;
          for (let suffix = 2; occupied.has(slug); suffix++) {
            slug = `${base}_${suffix}`;
          }
          return slug;
        };
        await tx.insert(schema.organization).values({ id: userId, name: "Personal", slug: await availableSlug(user.email.split("@")[0]!), kind: "personal", createdAt: user.createdAt });
        await tx.insert(schema.member).values({ id: userId, userId, organizationId: userId, role: "owner", createdAt: user.createdAt });
        await tx.insert(schema.syncedWorkspace).values({ workspaceId: userId, organizationId: userId, createdBy: { id: user.id, name: user.name, email: user.email }, name: "Personal", createdAt: user.createdAt, updatedAt: user.createdAt });
        await tx.insert(schema.syncedWorkspacePermission).values({ workspaceId: userId, principalType: "user", principalId: userId, role: "admin", grantedByUserId: userId });
        if (user.registrationState === "domain") {
          const email = headerEmail(user.email);
          const domain = email?.slice(email.lastIndexOf("@") + 1);
          if (domain && !isSharedEmailDomain(domain)) {
            const [existing] = await tx.select({ organizationId: schema.organizationAutoJoinDomain.organizationId })
              .from(schema.organizationAutoJoinDomain).where(eq(schema.organizationAutoJoinDomain.domain, domain));
            if (existing) await tx.insert(schema.member).values({ id: uuidV7(), userId,
              organizationId: existing.organizationId, role: "member", createdAt: user.createdAt });
          }
        }
        await tx.update(schema.user).set({ registrationState: "ready" }).where(eq(schema.user.id, userId));
      });
    },
    async transaction(action) {
      return transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        if (isPostgres) await tx.execute(sql`select set_config('app.maintenance', 'authorization', true)`);
        const before = await readAuthorization(tx, schema);
        const adapter = drizzleAdapter(tx, { provider: isPostgres ? "pg" : "sqlite", schema: isPostgres ? postgresAuth : sqliteAuth, transaction: false });
        const value = await action(adapter, createOrganizationStore(tx, isPostgres, true));
        const after = await readAuthorization(tx, schema);
        for (const member of before.members.filter((m) => !after.members.some((current) => current.id === m.id))) {
          const teams = before.teams.filter((t) => t.organizationId === member.organizationId).map((t) => t.id);
          if (teams.length) await tx.delete(schema.teamMember).where(and(eq(schema.teamMember.userId, member.userId), inArray(schema.teamMember.teamId, teams)));
        }
        for (const [type, removed] of [
          ["organization", before.organizations.filter((o) => !after.organizations.some((current) => current.id === o.id))],
          ["team", before.teams.filter((t) => !after.teams.some((current) => current.id === t.id))],
        ] as const) {
          if (removed.length) await tx.delete(schema.syncedWorkspacePermission).where(and(eq(schema.syncedWorkspacePermission.principalType, type), inArray(schema.syncedWorkspacePermission.principalId, removed.map((v) => v.id))));
        }
        validateAuthorization(await readAuthorization(tx, schema), before);
        return value;
      });
    },
    async addTeamCreator(teamId, userId) {
      await db.insert(schema.teamMember).values({ id: uuidV7(), teamId, userId, createdAt: new Date() });
    },
    async assertTeamOrganization(organizationId) {
      const [org] = await db.select({ kind: schema.organization.kind }).from(schema.organization).where(eq(schema.organization.id, organizationId));
      if (!org || org.kind !== "team") authorizationConflict("personal_organization_immutable");
    },
  };
}
