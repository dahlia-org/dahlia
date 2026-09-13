import { and, eq, exists, inArray, or, sql, type AnyColumn } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";
import type { WorkspaceRole } from "../sync/types";

export const canWriteWorkspace = (role: unknown): role is "admin" | "editor" => role === "admin" || role === "editor";
export const canAdminWorkspace = (role: unknown): role is "admin" => role === "admin";

/** Team grants require current membership of both the Team and its Organization. */
export function workspacePermissions(db: NodePgDatabase, schema: typeof Schema, userId: string | AnyColumn) {
  const p = schema.syncedWorkspacePermission;
  const matchingPrincipal = () => or(
    and(eq(p.principalType, "user"), eq(p.principalId, userId)),
    and(eq(p.principalType, "organization"), exists(db.select({ id: schema.member.id }).from(schema.member)
      .where(and(eq(schema.member.userId, userId), eq(schema.member.organizationId, p.principalId))))),
    and(eq(p.principalType, "team"), exists(db.select({ id: schema.teamMember.id }).from(schema.teamMember)
      .innerJoin(schema.team, eq(schema.team.id, schema.teamMember.teamId))
      .innerJoin(schema.member, and(eq(schema.member.organizationId, schema.team.organizationId), eq(schema.member.userId, userId)))
      .where(and(eq(schema.teamMember.userId, userId), eq(schema.teamMember.teamId, p.principalId))))),
  );
  const access = (workspace: AnyColumn, roles: WorkspaceRole[]) => exists(db.select({ id: p.workspaceId }).from(p)
    .where(and(eq(p.workspaceId, workspace), inArray(p.role, roles), matchingPrincipal())));
  const admin = (workspace: AnyColumn) => access(workspace, ["admin"]);
  const write = (workspace: AnyColumn) => access(workspace, ["admin", "editor"]);
  const read = (workspace: AnyColumn) => access(workspace, ["admin", "editor", "viewer"]);
  const role = (workspace: AnyColumn) => sql<WorkspaceRole>`case when ${admin(workspace)} then 'admin' when ${write(workspace)} then 'editor' else 'viewer' end`;
  return { admin, write, read, role, matchingPrincipal };
}
