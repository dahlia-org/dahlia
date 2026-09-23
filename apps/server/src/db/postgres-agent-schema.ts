import { syncedMeeting } from "./postgres-app-schema";
import { boolean, integer, uuid, index, jsonb, pgPolicy, pgSchema, text, timestamp, type AnyPgColumn } from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";

export const agentSchema = pgSchema("agent");
const currentUser = sql`nullif(current_setting('app.user_id', true), '')`;

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
  pgPolicy("agent_thread_owner", { for: "all", using: sql`${table.resourceId} = ${currentUser}`,
    withCheck: sql`${table.resourceId} = ${currentUser}` }),
]).enableRLS();

const ownedThread = (threadId: AnyPgColumn) => sql`EXISTS (
  SELECT 1 FROM ${agentThreads} owner_thread
  WHERE owner_thread.id = ${threadId} AND owner_thread."resourceId" = ${currentUser}
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
  pgPolicy("agent_message_owner", { for: "all",
    using: sql`${ownedThread(table.threadId)} AND (${table.resourceId} IS NULL OR ${table.resourceId} = ${currentUser})`,
    withCheck: sql`${ownedThread(table.threadId)} AND (${table.resourceId} IS NULL OR ${table.resourceId} = ${currentUser})` }),
]).enableRLS();

export const agentResources = agentSchema.table("mastra_resources", {
  id: text("id").primaryKey(),
  workingMemory: text("workingMemory"),
  metadata: jsonb("metadata").$type<Record<string, unknown>>(),
  createdAt: timestamp("createdAt").notNull(),
  createdAtZ: timestamp("createdAtZ", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updatedAt").notNull(),
  updatedAtZ: timestamp("updatedAtZ", { withTimezone: true }).defaultNow(),
}, (table) => [pgPolicy("agent_resource_owner", { for: "all", using: sql`${table.id} = ${currentUser}`,
  withCheck: sql`${table.id} = ${currentUser}` })]).enableRLS();

export const aiThreadRuns = agentSchema.table("ai_thread_runs", {
  threadId: text("thread_id").primaryKey().references(() => agentThreads.id, { onDelete: "cascade" }),
  runId: text("run_id").notNull(),
  resourceId: text("resource_id").notNull(),
  startedAt: timestamp("started_at", { withTimezone: true }).defaultNow().notNull(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
}, (table) => [pgPolicy("ai_thread_run_owner", { for: "all",
  using: sql`${table.resourceId} = ${currentUser} AND ${ownedThread(table.threadId)}`,
  withCheck: sql`${table.resourceId} = ${currentUser} AND ${ownedThread(table.threadId)}` })]).enableRLS();

// Mirrors the pinned Mastra core/pg schema; initialization remains migration-owned.
export const agentObservations = agentSchema.table("mastra_observational_memory", {
  id: text("id").primaryKey(),
  lookupKey: text("lookupKey").notNull(),
  scope: text("scope").notNull(),
  resourceId: text("resourceId"),
  threadId: text("threadId").references(() => agentThreads.id, { onDelete: "cascade" }),
  activeObservations: text("activeObservations").notNull(),
  activeObservationsPendingUpdate: text("activeObservationsPendingUpdate"),
  originType: text("originType").notNull(),
  config: text("config").notNull(),
  generationCount: integer("generationCount").notNull(),
  lastObservedAt: timestamp("lastObservedAt"),
  lastObservedAtZ: timestamp("lastObservedAtZ", { withTimezone: true }),
  lastReflectionAt: timestamp("lastReflectionAt"),
  lastReflectionAtZ: timestamp("lastReflectionAtZ", { withTimezone: true }),
  pendingMessageTokens: integer("pendingMessageTokens").notNull(),
  totalTokensObserved: integer("totalTokensObserved").notNull(),
  observationTokenCount: integer("observationTokenCount").notNull(),
  isObserving: boolean("isObserving").notNull(),
  isReflecting: boolean("isReflecting").notNull(),
  observedMessageIds: jsonb("observedMessageIds"),
  observedTimezone: text("observedTimezone"),
  bufferedObservations: text("bufferedObservations"),
  bufferedObservationTokens: integer("bufferedObservationTokens"),
  bufferedMessageIds: jsonb("bufferedMessageIds"),
  bufferedReflection: text("bufferedReflection"),
  bufferedReflectionTokens: integer("bufferedReflectionTokens"),
  bufferedReflectionInputTokens: integer("bufferedReflectionInputTokens"),
  reflectedObservationLineCount: integer("reflectedObservationLineCount"),
  bufferedObservationChunks: jsonb("bufferedObservationChunks"),
  isBufferingObservation: boolean("isBufferingObservation").notNull(),
  isBufferingReflection: boolean("isBufferingReflection").notNull(),
  lastBufferedAtTokens: integer("lastBufferedAtTokens").notNull(),
  lastBufferedAtTime: timestamp("lastBufferedAtTime"),
  lastBufferedAtTimeZ: timestamp("lastBufferedAtTimeZ", { withTimezone: true }),
  metadata: jsonb("metadata"),
  createdAt: timestamp("createdAt").notNull(),
  createdAtZ: timestamp("createdAtZ", { withTimezone: true }),
  updatedAt: timestamp("updatedAt").notNull(),
  updatedAtZ: timestamp("updatedAtZ", { withTimezone: true }),
}, (table) => [index("agent_om_lookup_idx").on(table.lookupKey),
  pgPolicy("agent_observation_owner", { for: "all",
    using: sql`${table.scope} = 'thread' AND ${table.resourceId} = ${currentUser} AND ${ownedThread(table.threadId)}`,
    withCheck: sql`${table.scope} = 'thread' AND ${table.resourceId} = ${currentUser} AND ${ownedThread(table.threadId)}` }),
]).enableRLS();

export const agentMemoryJobs = agentSchema.table("memory_jobs", {
  id: text("id").primaryKey(), userId: text("user_id").notNull(),
  threadId: text("thread_id").notNull().references(() => agentThreads.id, { onDelete: "cascade" }),
  kind: text("kind").notNull(), messageId: text("message_id"), revision: integer("revision").notNull(),
  availableAt: timestamp("available_at", { withTimezone: true }).defaultNow().notNull(),
  lease: text("lease"), leaseUntil: timestamp("lease_until", { withTimezone: true }),
  attempts: integer("attempts").default(0).notNull(),
}, (table) => [index("agent_memory_due_idx").on(table.availableAt),
  pgPolicy("agent_memory_job_owner", { for: "all", using: sql`${table.userId} = ${currentUser} AND ${ownedThread(table.threadId)}`,
    withCheck: sql`${table.userId} = ${currentUser} AND ${ownedThread(table.threadId)}` }),
  pgPolicy("agent_memory_job_dispatch", { for: "select", using: sql`current_setting('app.maintenance', true) = 'agent-memory'` }),
]).enableRLS();

export const agentLiveContexts = agentSchema.table("live_contexts", {
  meetingId: uuid("meeting_id").primaryKey().references(() => syncedMeeting.meetingId, { onDelete: "cascade" }),
  snapshot: jsonb("snapshot"), lease: text("lease"), leaseUntil: timestamp("lease_until", { withTimezone: true }),
}, (table) => [pgPolicy("agent_live_reader", { for: "all",
  using: sql`EXISTS (SELECT 1 FROM app.meetings m WHERE m.meeting_id = ${table.meetingId} AND m.deleted_at IS NULL AND m.deleting_at IS NULL AND app.current_identity_can_read_workspace(m.workspace_id))`,
  withCheck: sql`EXISTS (SELECT 1 FROM app.meetings m WHERE m.meeting_id = ${table.meetingId} AND m.deleted_at IS NULL AND m.deleting_at IS NULL AND app.current_identity_can_read_workspace(m.workspace_id))` }),
]).enableRLS();
