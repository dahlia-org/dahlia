import { and, eq, exists, inArray, or, sql, type AnyColumn } from "drizzle-orm";
import type { NodePgDatabase } from "drizzle-orm/node-postgres";
import type * as Schema from "../db/auth-schema";
import type { VaultRole } from "../sync/types";

export const canWriteVault = (role: unknown): role is "admin" | "editor" => role === "admin" || role === "editor";
export const canAdminVault = (role: unknown): role is "admin" => role === "admin";

/** Team grants require current membership of both the Team and its Organization. */
export function vaultPermissions(db: NodePgDatabase, schema: typeof Schema, userId: string | AnyColumn) {
  const p = schema.syncedVaultPermission;
  const matchingPrincipal = () => or(
    and(eq(p.principalType, "user"), eq(p.principalId, userId)),
    and(eq(p.principalType, "organization"), exists(db.select({ id: schema.member.id }).from(schema.member)
      .where(and(eq(schema.member.userId, userId), eq(schema.member.organizationId, p.principalId))))),
    and(eq(p.principalType, "team"), exists(db.select({ id: schema.teamMember.id }).from(schema.teamMember)
      .innerJoin(schema.team, eq(schema.team.id, schema.teamMember.teamId))
      .innerJoin(schema.member, and(eq(schema.member.organizationId, schema.team.organizationId), eq(schema.member.userId, userId)))
      .where(and(eq(schema.teamMember.userId, userId), eq(schema.teamMember.teamId, p.principalId))))),
  );
  const access = (vault: AnyColumn, roles: VaultRole[]) => exists(db.select({ id: p.vaultId }).from(p)
    .where(and(eq(p.vaultId, vault), inArray(p.role, roles), matchingPrincipal())));
  const admin = (vault: AnyColumn) => access(vault, ["admin"]);
  const write = (vault: AnyColumn) => access(vault, ["admin", "editor"]);
  const read = (vault: AnyColumn) => access(vault, ["admin", "editor", "viewer"]);
  const role = (vault: AnyColumn) => sql<VaultRole>`case when ${admin(vault)} then 'admin' when ${write(vault)} then 'editor' else 'viewer' end`;
  return { admin, write, read, role, matchingPrincipal };
}
