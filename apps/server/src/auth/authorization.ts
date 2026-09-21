import { eq, sql } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import { APIError } from "better-auth/api";
import type * as Schema from "../db/auth-schema";
import { isReservedTeamOrganizationSlug, organizationSlugPattern } from "./organization-slug";

export const authorizationConflict = (message: string): never => { throw new APIError("CONFLICT", { message, code: message }); };

export async function readAuthorization(db: NodePgDatabase, schema: typeof Schema) {
  // ponytail: scan authorization metadata under one lock; scope snapshots if organization count becomes large.
  const [organizations, members, teams, teamMembers, permissions, workspaces, invitations, administrators] = await Promise.all([
    db.select().from(schema.organization), db.select().from(schema.member), db.select().from(schema.team),
    db.select().from(schema.teamMember), db.select().from(schema.syncedWorkspacePermission),
    db.select({ workspaceId: schema.syncedWorkspace.workspaceId, organizationId: schema.syncedWorkspace.organizationId, personalUserId: schema.syncedWorkspace.personalUserId }).from(schema.syncedWorkspace),
    db.select({ organizationId: schema.invitation.organizationId }).from(schema.invitation),
    db.select({ id: schema.user.id }).from(schema.user)
      .where(sql`(',' || coalesce(${schema.user.role}, 'user') || ',') like '%,admin,%'`).limit(1),
  ]);
  return { organizations, members, teams, teamMembers, permissions, workspaces, invitations, administrators };
}
export type AuthorizationState = Awaited<ReturnType<typeof readAuthorization>>;

export function validateAuthorization(state: AuthorizationState, before?: AuthorizationState) {
  if (before?.administrators.length && !state.administrators.length) authorizationConflict("last_admin");
  for (const team of state.teams) {
    const previous = before?.teams.find((t) => t.id === team.id);
    if (previous && previous.organizationId !== team.organizationId) authorizationConflict("team_organization_immutable");
  }
  if (state.members.some((m) => !["owner", "admin", "member"].includes(m.role))) authorizationConflict("invalid_organization_role");
  for (const org of state.organizations) {
    const previousSlug = before?.organizations.find((previous) => previous.id === org.id)?.slug;
    // Sharing validation has no before snapshot and must preserve legacy slug syntax.
    if (before && previousSlug !== org.slug && !organizationSlugPattern.test(org.slug)) authorizationConflict("invalid_organization_slug");
    if (isReservedTeamOrganizationSlug(org.slug)) authorizationConflict("reserved_organization_slug");
  }
  const memberOf = (userId: string, organizationId: string) => state.members.some((m) => m.userId === userId && m.organizationId === organizationId);
  for (const organization of state.organizations) {
    const members = state.members.filter((m) => m.organizationId === organization.id);
    if (!members.some((m) => m.role === "owner")) authorizationConflict("last_organization_owner");
  }
  for (const team of state.teams) {
    const members = state.teamMembers.filter((m) => m.teamId === team.id);
    if (!members.some((m) => memberOf(m.userId, team.organizationId))) authorizationConflict("last_team_member");
    if (members.some((m) => !memberOf(m.userId, team.organizationId))) authorizationConflict("team_requires_organization_member");
  }
  for (const workspace of state.workspaces) {
    const permissions = state.permissions.filter((p) => p.workspaceId === workspace.workspaceId);
    if (workspace.personalUserId) {
      if (permissions.length !== 1 || permissions[0]!.principalType !== "user" || permissions[0]!.principalId !== workspace.personalUserId || permissions[0]!.role !== "admin") authorizationConflict("personal_workspace_immutable");
      // A departed member's private data is retained, with access gated by current membership.
      continue;
    }
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
    if (!effectiveAdmin) authorizationConflict("last_workspace_admin");
  }
}

export async function lockAuthorization(db: NodePgDatabase, schema: typeof Schema, isPostgres: boolean) {
  if (isPostgres) await db.execute(sql`select pg_advisory_xact_lock(75047176522050)`);
  await db.insert(schema.serverSettings).values({ id: 1 }).onConflictDoNothing();
  await db.update(schema.serverSettings).set({ id: 1 }).where(eq(schema.serverSettings.id, 1));
}
