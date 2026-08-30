import { sql } from "drizzle-orm";
import { boolean, check, pgSchema, text, timestamp } from "drizzle-orm/pg-core";

export const dahliaSchema = pgSchema("dahlia");

export const modelAlias = dahliaSchema.table("model_alias", {
  alias: text("alias").primaryKey(),
  upstreamModel: text("upstream_model").notNull(),
  displayName: text("display_name"),
  enabled: boolean("enabled").default(true).notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
});

export const platformAdmin = dahliaSchema.table("platform_admin", {
  email: text("email").primaryKey(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
});

export const artifact = dahliaSchema.table("artifact", {
  id: text("id").primaryKey(),
  ownerWorkspaceId: text("owner_workspace_id").notNull(),
  contentType: text("content_type").notNull(),
  storageKey: text("storage_key"),
  visibility: text("visibility").default("private").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
}, (table) => [
  check("artifact_visibility_check", sql`${table.visibility} IN ('private', 'public')`),
]);

export const artifactReservation = dahliaSchema.table("artifact_reservation", {
  id: text("id").primaryKey(),
});
