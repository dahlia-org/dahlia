import { and, eq, inArray, sql } from "drizzle-orm";
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
import { headerEmail } from "./header";
import { authorizationConflict, lockAuthorization, readAuthorization, validateAuthorization } from "./authorization";

export interface OrganizationStore {
  initializeUser(userId: string, headerProviderId?: string): Promise<void>;
  transaction<T>(action: (database: DBAdapterInstance, organizations: OrganizationStore) => Promise<T>): Promise<T>;
  addTeamCreator(teamId: string, userId: string): Promise<void>;
  assertTeamOrganization(organizationId: string): Promise<void>;
}

export function createOrganizationStore(connection: NodePgDatabase | SQLiteDatabase, isPostgres: boolean, inTransaction = false): OrganizationStore {
  const db = connection as NodePgDatabase;
  const schema = isPostgres ? postgres : sqlite as unknown as typeof postgres;
  const transaction = async <T>(action: (tx: NodePgDatabase) => Promise<T>) => inTransaction ? action(db) : db.transaction(action);
  return {
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
        await tx.insert(schema.organization).values({ id: userId, name: "Personal", slug: `personal-${userId}`, kind: "personal", createdAt: user.createdAt });
        await tx.insert(schema.member).values({ id: userId, userId, organizationId: userId, role: "owner", createdAt: user.createdAt });
        await tx.insert(schema.syncedVault).values({ vaultId: userId, organizationId: userId, createdBy: { id: user.id, name: user.name, email: user.email }, name: "Personal", createdAt: user.createdAt, updatedAt: user.createdAt });
        await tx.insert(schema.syncedVaultPermission).values({ vaultId: userId, principalType: "user", principalId: userId, role: "admin", grantedByUserId: userId });
        if (user.registrationState === "domain") {
          const domain = user.email.slice(user.email.lastIndexOf("@") + 1);
          const [existing] = await tx.select({ id: schema.organization.id }).from(schema.organization).where(eq(schema.organization.domain, domain));
          const organizationId = existing?.id ?? uuidV7();
          if (!existing) await tx.insert(schema.organization).values({ id: organizationId, name: domain, slug: `domain-${organizationId}`, kind: "team", domain, createdAt: user.createdAt });
          await tx.insert(schema.member).values({ id: uuidV7(), userId, organizationId, role: existing ? "member" : "owner", createdAt: user.createdAt });
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
          if (removed.length) await tx.delete(schema.syncedVaultPermission).where(and(eq(schema.syncedVaultPermission.principalType, type), inArray(schema.syncedVaultPermission.principalId, removed.map((v) => v.id))));
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
