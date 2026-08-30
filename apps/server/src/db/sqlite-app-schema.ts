import { sql } from "drizzle-orm";
import { check, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

const sqliteTimestamp = (name: string) => integer(name, { mode: "timestamp_ms" });

export const modelAlias = sqliteTable("model_alias", {
  alias: text("alias").primaryKey(),
  upstreamModel: text("upstream_model").notNull(),
  displayName: text("display_name"),
  enabled: integer("enabled", { mode: "boolean" }).default(true).notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
});

export const platformAdmin = sqliteTable("platform_admin", {
  email: text("email").primaryKey(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
});

export const artifact = sqliteTable("artifact", {
  id: text("id").primaryKey(),
  ownerWorkspaceId: text("owner_workspace_id").notNull(),
  contentType: text("content_type").notNull(),
  storageKey: text("storage_key"),
  visibility: text("visibility").default("private").notNull(),
  createdAt: sqliteTimestamp("created_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
  updatedAt: sqliteTimestamp("updated_at").default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`).notNull(),
}, (table) => [
  check("artifact_visibility_check", sql`${table.visibility} IN ('private', 'public')`),
]);

export const artifactReservation = sqliteTable("artifact_reservation", {
  id: text("id").primaryKey(),
});
