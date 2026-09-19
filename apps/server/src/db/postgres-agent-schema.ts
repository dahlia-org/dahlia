import { index, jsonb, pgPolicy, pgSchema, text, timestamp, type AnyPgColumn } from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";

export const agentSchema = pgSchema("agent");
const currentResource = sql`"agent"."user_resource_id"(nullif(current_setting('app.user_id', true), '')::uuid)`;

export const agentThreads = agentSchema.table("mastra_threads", {
  id: text("id").primaryKey(),
  resourceId: text("resourceId").notNull(),
  title: text("title").notNull(),
  metadata: jsonb("metadata").$type<Record<string, unknown>>(),
  createdAt: timestamp("createdAt").notNull(),
  createdAtZ: timestamp("createdAtZ", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updatedAt").notNull(),
  updatedAtZ: timestamp("updatedAtZ", { withTimezone: true }).defaultNow(),
}, (table) => [
  index("agent_mastra_threads_resourceid_createdat_idx").on(table.resourceId, table.createdAt.desc()),
  pgPolicy("agent_thread_owner", { for: "all", using: sql`${table.resourceId} = ${currentResource}`,
    withCheck: sql`${table.resourceId} = ${currentResource}` }),
]).enableRLS();

const ownedThread = (threadId: AnyPgColumn) => sql`EXISTS (
  SELECT 1 FROM ${agentThreads} owner_thread
  WHERE owner_thread.id = ${threadId} AND owner_thread."resourceId" = ${currentResource}
)`;

export const agentMessages = agentSchema.table("mastra_messages", {
  id: text("id").primaryKey(),
  threadId: text("thread_id").notNull(),
  content: text("content").notNull(),
  role: text("role").notNull(),
  type: text("type").notNull(),
  createdAt: timestamp("createdAt").notNull(),
  createdAtZ: timestamp("createdAtZ", { withTimezone: true }).defaultNow(),
  resourceId: text("resourceId"),
}, (table) => [
  index("agent_mastra_messages_thread_id_createdat_idx").on(table.threadId, table.createdAt.desc()),
  pgPolicy("agent_message_owner", { for: "all", using: ownedThread(table.threadId),
    withCheck: ownedThread(table.threadId) }),
]).enableRLS();

export const agentResources = agentSchema.table("mastra_resources", {
  id: text("id").primaryKey(),
  workingMemory: text("workingMemory"),
  metadata: jsonb("metadata").$type<Record<string, unknown>>(),
  createdAt: timestamp("createdAt").notNull(),
  createdAtZ: timestamp("createdAtZ", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updatedAt").notNull(),
  updatedAtZ: timestamp("updatedAtZ", { withTimezone: true }).defaultNow(),
}, (table) => [pgPolicy("agent_resource_owner", { for: "all", using: sql`${table.id} = ${currentResource}`,
  withCheck: sql`${table.id} = ${currentResource}` })]).enableRLS();

export const aiThreadRuns = agentSchema.table("ai_thread_runs", {
  threadId: text("thread_id").primaryKey().references(() => agentThreads.id, { onDelete: "cascade" }),
  runId: text("run_id").notNull(),
  resourceId: text("resource_id").notNull(),
  startedAt: timestamp("started_at", { withTimezone: true }).defaultNow().notNull(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
}, (table) => [pgPolicy("ai_thread_run_owner", { for: "all", using: sql`${table.resourceId} = ${currentResource}`,
  withCheck: sql`${table.resourceId} = ${currentResource}` })]).enableRLS();
