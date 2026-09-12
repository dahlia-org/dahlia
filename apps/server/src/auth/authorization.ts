import { eq, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { APIError } from "better-auth/api";
import type * as Schema from "../db/auth-schema";

export const authorizationConflict = (message: string): never => { throw new APIError("CONFLICT", { message, code: message }); };

export async function readAuthorization(db: NodePgDatabase, schema: typeof Schema) {
  // ponytail: scan authorization metadata under one lock; scope snapshots if organization count becomes large.
  const [organizations, members, teams, teamMembers, permissions, vaults, invitations, administrators] = await Promise.all([
    db.select().from(schema.organization), db.select().from(schema.member), db.select().from(schema.team),
    db.select().from(schema.teamMember), db.select().from(schema.syncedVaultPermission),
    db.select({ vaultId: schema.syncedVault.vaultId, organizationId: schema.syncedVault.organizationId }).from(schema.syncedVault),
    db.select({ organizationId: schema.invitation.organizationId }).from(schema.invitation),
    db.select({ id: schema.user.id }).from(schema.user)
      .where(sql`(',' || coalesce(${schema.user.role}, 'user') || ',') like '%,admin,%'`).limit(1),
  ]);
  return { organizations, members, teams, teamMembers, permissions, vaults, invitations, administrators };
}
export type AuthorizationState = Awaited<ReturnType<typeof readAuthorization>>;

export function validateAuthorization(state: AuthorizationState, before?: AuthorizationState) {
  if (before?.administrators.length && !state.administrators.length) authorizationConflict("last_admin");
  for (const previous of before?.organizations ?? []) {
    const current = state.organizations.find((o) => o.id === previous.id);
    if (!current && previous.kind === "personal") authorizationConflict("organization_delete_forbidden");
    if (current && current.domain !== previous.domain) authorizationConflict("organization_domain_immutable");
    if (current && (current.kind !== previous.kind || (previous.kind === "personal" && (current.slug !== previous.slug || current.logo !== previous.logo || current.metadata !== previous.metadata)))) authorizationConflict("personal_organization_immutable");
  }
  for (const team of state.teams) {
    const previous = before?.teams.find((t) => t.id === team.id);
    if (previous && previous.organizationId !== team.organizationId) authorizationConflict("team_organization_immutable");
  }
  if (state.members.some((m) => !["owner", "admin", "member"].includes(m.role))) authorizationConflict("invalid_organization_role");
  for (const org of state.organizations) {
    if (!["personal", "team"].includes(org.kind)) authorizationConflict("invalid_organization_kind");
    if (org.kind === "personal" && state.invitations.some((i) => i.organizationId === org.id)) authorizationConflict("personal_organization_immutable");
    if (org.kind === "team" && org.slug.toLowerCase().startsWith("personal-")) authorizationConflict("reserved_organization_slug");
    if (org.kind === "personal" && (org.slug !== `personal-${org.id}` || state.vaults.filter((v) => v.organizationId === org.id).length !== 1)) authorizationConflict("personal_organization_immutable");
  }
  const memberOf = (userId: string, organizationId: string) => state.members.some((m) => m.userId === userId && m.organizationId === organizationId);
  for (const organization of state.organizations) {
    const members = state.members.filter((m) => m.organizationId === organization.id);
    if (!members.some((m) => m.role === "owner")) authorizationConflict("last_organization_owner");
    if (organization.kind === "personal" && (members.length !== 1 || members[0]!.userId !== organization.id || members[0]!.role !== "owner"
      || state.teams.some((t) => t.organizationId === organization.id))) authorizationConflict("personal_organization_immutable");
  }
  for (const team of state.teams) {
    const members = state.teamMembers.filter((m) => m.teamId === team.id);
    if (!members.some((m) => memberOf(m.userId, team.organizationId))) authorizationConflict("last_team_member");
    if (members.some((m) => !memberOf(m.userId, team.organizationId))) authorizationConflict("team_requires_organization_member");
  }
  for (const vault of state.vaults) {
    const permissions = state.permissions.filter((p) => p.vaultId === vault.vaultId);
    if (permissions.some((p) => p.principalType === "organization" && state.organizations.some((o) => o.id === p.principalId && o.kind === "personal"))) authorizationConflict("personal_organization_principal_forbidden");
    const effectiveAdmin = permissions.some((permission) => {
      if (permission.role !== "admin") return false;
      switch (permission.principalType) {
        case "user":
          return true;
        case "organization":
          return state.members.some((member) => member.organizationId === permission.principalId);
        case "team":
          return state.teams.some((team) => team.id === permission.principalId
            && state.teamMembers.some((member) => member.teamId === team.id && memberOf(member.userId, team.organizationId)));
        default:
          return false;
      }
    });
    if (!effectiveAdmin) authorizationConflict("last_vault_admin");
    if (state.organizations.some((o) => o.id === vault.organizationId && o.kind === "personal")
      && (vault.vaultId !== vault.organizationId || permissions.length !== 1 || permissions[0]!.principalType !== "user"
        || permissions[0]!.principalId !== vault.organizationId || permissions[0]!.role !== "admin")) authorizationConflict("personal_vault_immutable");
  }
}

export async function lockAuthorization(db: NodePgDatabase, schema: typeof Schema, isPostgres: boolean) {
  if (isPostgres) await db.execute(sql`select pg_advisory_xact_lock(75047176522050)`);
  await db.insert(schema.serverSettings).values({ id: 1 }).onConflictDoNothing();
  await db.update(schema.serverSettings).set({ id: 1 }).where(eq(schema.serverSettings.id, 1));
}
