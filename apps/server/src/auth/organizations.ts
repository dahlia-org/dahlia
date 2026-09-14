import { and, desc, eq, getTableColumns, gt, inArray, lt, ne, notExists, or, sql } from "drizzle-orm";
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
import { organizationDomainsSchema, isSharedEmailDomain, type OrganizationDomains } from "./organization-domains";
import { createOrganizationSchema } from "./organization-slug";
import { headerEmail } from "./header";
import { authorizationConflict, lockAuthorization, readAuthorization, validateAuthorization } from "./authorization";

export type JoinRequest = typeof postgres.organizationJoinRequest.$inferSelect & { organizationName: string; userName: string; userEmail: string };

export interface OrganizationStore {
  getDomains(identity: Identity, organizationId: string): Promise<OrganizationDomains>;
  updateDomains(identity: Identity, organizationId: string, input: unknown): Promise<OrganizationDomains>;
  candidates(identity: Identity, cursor?: string): Promise<{ id: string; name: string; logo: string | null; joinPolicy: string; requestStatus: string | null }[]>;
  requests(identity: Identity, organizationId?: string, cursor?: string): Promise<JoinRequest[]>;
  join(identity: Identity, organizationId: string, request: boolean): Promise<void>;
  resolveRequest(identity: Identity, requestId: string, status: "approved" | "rejected" | "cancelled"): Promise<void>;
  create(identity: Identity, input: { name: string; slug: string; initialOwnerUserId: string }): Promise<{ id: string; name: string; slug: string; kind: string }>;
  delete(identity: Identity, organizationId: string): Promise<void>;
  initializeUser(userId: string, headerProviderId?: string): Promise<void>;
  transaction<T>(action: (database: DBAdapterInstance, organizations: OrganizationStore) => Promise<T>): Promise<T>;
  hasMember(userId: string, organizationId: string): Promise<boolean>;
  addTeamCreator(teamId: string, userId: string): Promise<void>;
  assertTeamOrganization(organizationId: string): Promise<void>;
}

export function createOrganizationStore(connection: NodePgDatabase | SQLiteDatabase, isPostgres: boolean, inTransaction = false): OrganizationStore {
  const db = connection as NodePgDatabase;
  const schema = isPostgres ? postgres : sqlite as unknown as typeof postgres;
  const transaction = async <T>(action: (tx: NodePgDatabase) => Promise<T>) => inTransaction ? action(db) : db.transaction(action);
  async function assertAccess(tx: NodePgDatabase, identity: Identity, organizationId: string, access: "read" | "manage" | "write") {
    const [membership] = await tx.select({ role: schema.member.role, kind: schema.organization.kind }).from(schema.member)
      .innerJoin(schema.organization, eq(schema.organization.id, schema.member.organizationId))
      .where(and(eq(schema.member.userId, identity.userId), eq(schema.member.organizationId, organizationId)));
    if (!membership || (access !== "read" && !["owner", "admin"].includes(membership.role)) || (access === "write" && identity.impersonated)) {
      throw new APIError("FORBIDDEN", { code: "organization_access_denied" });
    }
    if (access === "write" && membership.kind !== "team") authorizationConflict("personal_organization_immutable");
  }
  async function verifiedDomain(tx: NodePgDatabase, userId: string) {
    const [user] = await tx.select().from(schema.user).where(eq(schema.user.id, userId));
    if (!user?.emailVerified) return;
    const email = headerEmail(user.email);
    const domain = email?.slice(email.lastIndexOf("@") + 1);
    return domain && !isSharedEmailDomain(domain) ? domain : undefined;
  }
  async function policy(tx: NodePgDatabase, userId: string, organizationId: string) {
    const domain = await verifiedDomain(tx, userId);
    if (!domain) return;
    const [row] = await tx.select().from(schema.organizationDomain).where(and(eq(schema.organizationDomain.domain, domain), eq(schema.organizationDomain.organizationId, organizationId)));
    return row?.joinPolicy;
  }
  async function assertAdmin(tx: NodePgDatabase, identity: Identity) {
    const [user] = await tx.select().from(schema.user).where(eq(schema.user.id, identity.userId));
    if (identity.impersonated || !user?.role?.split(",").includes("admin")) throw new APIError("FORBIDDEN", { code: "admin_required" });
  }
  async function addMember(tx: NodePgDatabase, userId: string, organizationId: string) {
    await tx.insert(schema.member).values({ id: uuidV7(), userId, organizationId, role: "member", createdAt: new Date() }).onConflictDoNothing({ target: [schema.member.userId, schema.member.organizationId] });
  }
  return {
    async getDomains(identity, organizationId) {
      return transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        await assertAccess(tx, identity, organizationId, "read");
        const domains = await tx.select({ domain: schema.organizationDomain.domain, joinPolicy: schema.organizationDomain.joinPolicy }).from(schema.organizationDomain)
          .where(eq(schema.organizationDomain.organizationId, organizationId)).orderBy(schema.organizationDomain.domain);
        return { domains };
      });
    },
    async updateDomains(identity, organizationId, input) {
      return transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        await assertAccess(tx, identity, organizationId, "write");
        const parsed = organizationDomainsSchema.safeParse(input);
        if (!parsed.success || new Set(parsed.data.domains.map((row) => row.domain)).size !== parsed.data.domains.length) throw new APIError("BAD_REQUEST", { code: "invalid_organization_domain" });
        const domains = parsed.data.domains.sort((a, b) => a.domain.localeCompare(b.domain));
        if (domains.some(({ domain }) => isSharedEmailDomain(domain))) throw new APIError("BAD_REQUEST", { code: "shared_email_domain" });
        await tx.delete(schema.organizationDomain).where(eq(schema.organizationDomain.organizationId, organizationId));
        if (domains.length) await tx.insert(schema.organizationDomain).values(domains.map((row) => ({ ...row, organizationId })));
        const pending = await tx.select().from(schema.organizationJoinRequest).where(and(eq(schema.organizationJoinRequest.organizationId, organizationId), eq(schema.organizationJoinRequest.status, "pending")));
        for (const request of pending) {
          if (await policy(tx, request.userId, organizationId) !== "need_approval") await tx.update(schema.organizationJoinRequest).set({ status: "cancelled", resolvedAt: new Date(), resolvedBy: identity.userId }).where(eq(schema.organizationJoinRequest.id, request.id));
        }
        return { domains };
      });
    },
    async candidates(identity, cursor) {
      return transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        const domain = await verifiedDomain(tx, identity.userId);
        if (!domain) return [];
        const request = schema.organizationJoinRequest;
        return tx.select({ id: schema.organization.id, name: schema.organization.name, logo: schema.organization.logo, joinPolicy: schema.organizationDomain.joinPolicy,
          requestStatus: sql<string | null>`(select ${request.status} from ${request} where ${request.userId} = ${identity.userId} and ${request.organizationId} = ${schema.organization.id} order by ${request.createdAt} desc, ${request.id} desc limit 1)`,
        }).from(schema.organizationDomain).innerJoin(schema.organization, eq(schema.organization.id, schema.organizationDomain.organizationId))
          .where(and(eq(schema.organizationDomain.domain, domain), ne(schema.organizationDomain.joinPolicy, "invite_only"),
            cursor ? gt(schema.organization.id, cursor) : undefined,
            notExists(tx.select({ id: schema.member.id }).from(schema.member).where(and(eq(schema.member.userId, identity.userId), eq(schema.member.organizationId, schema.organization.id)))),
          )).orderBy(schema.organization.id).limit(101);
      });
    },
    async requests(identity, organizationId, cursor) {
      return transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        if (organizationId) await assertAccess(tx, identity, organizationId, "manage");
        return tx.select({ ...getTableColumns(schema.organizationJoinRequest), organizationName: schema.organization.name, userName: schema.user.name, userEmail: schema.user.email })
          .from(schema.organizationJoinRequest).innerJoin(schema.organization, eq(schema.organization.id, schema.organizationJoinRequest.organizationId))
          .innerJoin(schema.user, eq(schema.user.id, schema.organizationJoinRequest.userId))
          .where(and(organizationId ? eq(schema.organizationJoinRequest.organizationId, organizationId) : eq(schema.organizationJoinRequest.userId, identity.userId), cursor ? lt(schema.organizationJoinRequest.id, cursor) : undefined))
          .orderBy(desc(schema.organizationJoinRequest.id)).limit(101);
      });
    },
    async join(identity, organizationId, request) {
      return transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        if (identity.impersonated || await policy(tx, identity.userId, organizationId) !== (request ? "need_approval" : "auto_join")) throw new APIError("FORBIDDEN", { code: "organization_join_denied" });
        const [member] = await tx.select().from(schema.member).where(and(eq(schema.member.organizationId, organizationId), eq(schema.member.userId, identity.userId)));
        if (member) return;
        if (request) await tx.insert(schema.organizationJoinRequest).values({ id: uuidV7(), organizationId, userId: identity.userId, status: "pending", createdAt: new Date() }).onConflictDoNothing();
        else await addMember(tx, identity.userId, organizationId);
      });
    },
    async resolveRequest(identity, requestId, status) {
      return transaction(async (tx) => {
        await lockAuthorization(tx, schema, isPostgres);
        const [request] = await tx.select().from(schema.organizationJoinRequest).where(eq(schema.organizationJoinRequest.id, requestId));
        if (!request) throw new APIError("NOT_FOUND", { code: "join_request_not_found" });
        if (status === "cancelled") {
          if (identity.impersonated || request.userId !== identity.userId) throw new APIError("FORBIDDEN", { code: "organization_access_denied" });
        } else await assertAccess(tx, identity, request.organizationId, "write");
        if (request.status === status) return;
        if (request.status !== "pending") authorizationConflict("join_request_resolved");
        if (status === "approved") {
          if (await policy(tx, request.userId, request.organizationId) !== "need_approval") authorizationConflict("organization_join_denied");
          await addMember(tx, request.userId, request.organizationId);
        }
        await tx.update(schema.organizationJoinRequest).set({ status, resolvedAt: new Date(), resolvedBy: identity.userId }).where(eq(schema.organizationJoinRequest.id, requestId));
      });
    },
    async create(identity, input) {
      if (!inTransaction) return this.transaction(async (_, scoped) => scoped.create(identity, input));
      await assertAdmin(db, identity);
      const parsed = createOrganizationSchema.safeParse(input);
      if (!parsed.success) throw new APIError("BAD_REQUEST", { code: "invalid_organization" });
      input = parsed.data;
      const [owner] = await db.select().from(schema.user).where(eq(schema.user.id, input.initialOwnerUserId));
      if (!owner) throw new APIError("BAD_REQUEST", { code: "initial_owner_not_found" });
      const [existing] = await db.select().from(schema.organization).where(eq(schema.organization.slug, input.slug));
      if (existing) authorizationConflict("organization_slug_in_use");
      const org = { id: uuidV7(), name: input.name, slug: input.slug, kind: "team", createdAt: new Date() };
      await db.insert(schema.organization).values(org);
      await db.insert(schema.member).values({ id: uuidV7(), userId: owner.id, organizationId: org.id, role: "owner", createdAt: org.createdAt });
      return org;
    },
    async delete(identity, organizationId) {
      if (!inTransaction) return this.transaction(async (_, scoped) => scoped.delete(identity, organizationId));
      await assertAdmin(db, identity);
      await this.assertTeamOrganization(organizationId);
      const [workspace] = await db.select({ id: schema.syncedWorkspace.workspaceId }).from(schema.syncedWorkspace).where(eq(schema.syncedWorkspace.organizationId, organizationId)).limit(1);
      if (workspace) authorizationConflict("organization_has_workspaces");
      await db.delete(schema.organization).where(eq(schema.organization.id, organizationId));
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
        if (user.emailVerified && user.registrationState === "domain") {
          const email = headerEmail(user.email);
          const domain = email?.slice(email.lastIndexOf("@") + 1);
          if (domain && !isSharedEmailDomain(domain)) {
            const existing = await tx.select({ organizationId: schema.organizationDomain.organizationId })
              .from(schema.organizationDomain).where(and(eq(schema.organizationDomain.domain, domain), eq(schema.organizationDomain.joinPolicy, "auto_join")));
            for (const org of existing) await addMember(tx, userId, org.organizationId);
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
          if (!removed.length) continue;
          const ids = removed.map((v) => v.id);
          await tx.delete(schema.syncedWorkspacePermission).where(and(eq(schema.syncedWorkspacePermission.principalType, type), inArray(schema.syncedWorkspacePermission.principalId, ids)));
          await tx.update(schema.session).set(type === "organization" ? { activeOrganizationId: null } : { activeTeamId: null })
            .where(inArray(type === "organization" ? schema.session.activeOrganizationId : schema.session.activeTeamId, ids));
        }
        validateAuthorization(await readAuthorization(tx, schema), before);
        return value;
      });
    },
    async hasMember(userId, organizationId) {
      const [member] = await db.select({ id: schema.member.id }).from(schema.member).where(and(eq(schema.member.userId, userId), eq(schema.member.organizationId, organizationId))).limit(1);
      return member !== undefined;
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
