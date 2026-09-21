import { and, eq, exists, inArray, or, sql, type AnyColumn } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";
import type { WorkspaceRole } from "../sync/types";

export const canWriteWorkspace = (role: unknown): role is "admin" | "editor" => role === "admin" || role === "editor";
export const canAdminWorkspace = (role: unknown): role is "admin" => role === "admin";

/** Team grants require current membership of both the Team and its Organization. */
export function workspacePermissions(db: NodePgDatabase, schema: typeof Schema, userId: string | AnyColumn) {
  const p = schema.syncedWorkspacePermission;
  const w = alias(schema.syncedWorkspace, "authorized_workspace");
  const matchingPrincipal = () => or(
    and(eq(p.principalType, "user"), eq(p.principalId, userId)),
    and(eq(p.principalType, "organization"), exists(db.select({ id: schema.member.id }).from(schema.member)
      .where(and(eq(schema.member.userId, userId), eq(schema.member.organizationId, p.principalId))))),
    and(eq(p.principalType, "team"), exists(db.select({ id: schema.teamMember.id }).from(schema.teamMember)
      .innerJoin(schema.team, eq(schema.team.id, schema.teamMember.teamId))
      .innerJoin(schema.member, and(eq(schema.member.organizationId, schema.team.organizationId), eq(schema.member.userId, userId)))
      .where(and(eq(schema.teamMember.userId, userId), eq(schema.teamMember.teamId, p.principalId))))),
  );
  // Keep this repeated predicate flat: nested query builders add significant snapshot compilation cost.
  const access = (workspace: AnyColumn, roles: WorkspaceRole[]) => sql`exists (
    select 1 from ${p}
    inner join ${schema.syncedWorkspace} as "authorized_workspace" on ${w.workspaceId} = ${p.workspaceId}
    where ${p.workspaceId} = ${workspace} and ${inArray(p.role, roles)} and ${matchingPrincipal()}
      and (${w.personalUserId} is null or (${w.personalUserId} = ${userId} and exists (
        select 1 from ${schema.member}
        where ${schema.member.userId} = ${userId} and ${schema.member.organizationId} = ${w.organizationId}
      )))
  )`;
  const admin = (workspace: AnyColumn) => access(workspace, ["admin"]);
  const write = (workspace: AnyColumn) => access(workspace, ["admin", "editor"]);
  const read = (workspace: AnyColumn) => access(workspace, ["admin", "editor", "viewer"]);
  const role = (workspace: AnyColumn) => sql<WorkspaceRole>`case when ${admin(workspace)} then 'admin' when ${write(workspace)} then 'editor' else 'viewer' end`;
  return { admin, write, read, role, matchingPrincipal };
}
