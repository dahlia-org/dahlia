import { drizzle } from "drizzle-orm/node-postgres";
import { and, eq } from "drizzle-orm";
import * as schema from "../db/auth-schema";
import { cancelJobs, enqueueJob, lockJob, settleJob } from "../jobs/state";
import { createJobStore, type BackgroundJob } from "../jobs/store";
import { defaultJobLimits } from "../jobs/model";
import type { Pool, PoolClient } from "pg";
import type { Identity } from "../auth/identity";
import { uuidV7 } from "../id";
import { RequestError } from "../storage/upload";
import { withIdentityTransaction } from "./history";
import { workingMemoryContentSchema, liveSnapshotSchema,
  type WorkingMemoryEdit, type WorkingMemorySettings, type LiveSnapshot } from "./context-model";

type ProfileMetadata = WorkingMemorySettings & { learningRevision: number; manualRevision: number; learnedRevision: number };
export interface MemoryJob { queue?: BackgroundJob; id: string; userId: string; threadId: string; kind: "working" | "live";
  messageId: string | null; revision: number; lease: string; attempts: number }
const defaults = (): ProfileMetadata => ({ revision: 0, learningRevision: 0, manualRevision: 0, learnedRevision: 0,
  automatic: true, capacityReached: false, manual: "", learned: "" });
const template = ({ manual, learned }: ProfileMetadata) => `# Working Memory\n\n## User notes\n${manual || "(none)"}\n\n## Learned from direct user statements\n${learned || "(none)"}`;
export const workingMemoryTemplate = template(defaults());

export class ChatMemoryStore {
  constructor(private readonly pool: Pool) {}
  private scoped<T>(identity: Identity, action: (client: PoolClient) => Promise<T>) {
    return withIdentityTransaction(this.pool, identity, action);
  }
  private async profile(client: PoolClient, userId: string) {
    const { rows: [row] } = await client.query<{ metadata: { workingMemory?: ProfileMetadata } | null }>(
      'SELECT "workingMemory", metadata FROM agent.mastra_resources WHERE id = $1', [userId]);
    return row?.metadata?.workingMemory ?? defaults();
  }
  private async saveProfile(client: PoolClient, userId: string, metadata: ProfileMetadata) {
    await client.query(`INSERT INTO agent.mastra_resources (id, "workingMemory", metadata, "createdAt", "updatedAt", "createdAtZ", "updatedAtZ")
      VALUES ($1, $2, $3, now(), now(), now(), now()) ON CONFLICT (id) DO UPDATE SET
      "workingMemory" = EXCLUDED."workingMemory", metadata = COALESCE(agent.mastra_resources.metadata, '{}'::jsonb) || EXCLUDED.metadata,
      "updatedAt" = now(), "updatedAtZ" = now()`, [userId, template(metadata), JSON.stringify({ workingMemory: metadata })]);
  }
  async settings(identity: Identity): Promise<WorkingMemorySettings> {
    return this.scoped(identity, async (client) => {
      const { revision, automatic, capacityReached, manual, learned } = await this.profile(client, identity.userId);
      return { revision, automatic, capacityReached, manual, learned };
    });
  }
  async editSettings(identity: Identity, input: WorkingMemoryEdit) {
    if (identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    return this.scoped(identity, async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 1))", [identity.userId]);
      const metadata = await this.profile(client, identity.userId);
      const changedAt = input.section === "manual" ? metadata.manualRevision
        : input.section === "learned" ? metadata.learnedRevision : metadata.revision;
      if (input.revision > metadata.revision || input.revision < changedAt) throw new RequestError(409, "memory_revision_conflict");
      if (input.section === "settings") {
        metadata.automatic = input.automatic;
        if (input.automatic) metadata.capacityReached = false;
      } else {
        if (!input.explicit) throw new RequestError(403, "memory_explicit_instruction_required");
        metadata[input.section] = input.content;
        if (input.section === "learned") metadata.capacityReached = false;
      }
      metadata.revision++;
      if (input.section === "manual") metadata.manualRevision = metadata.revision;
      if (input.section === "learned") metadata.learnedRevision = metadata.revision;
      if (input.section !== "manual") metadata.learningRevision = metadata.revision;
      await this.saveProfile(client, identity.userId, metadata);
      const { revision, automatic, capacityReached, manual, learned } = metadata;
      return { revision, automatic, capacityReached, manual, learned };
    });
  }
  async applyLearned(identity: Identity, job: MemoryJob, note: string | null) {
    return this.scoped(identity, async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 1))", [identity.userId]);
      if (job.queue && !await lockJob(drizzle({ client }), schema, job.queue)) return;
      const metadata = await this.profile(client, identity.userId);
      if (!metadata.automatic || !note || job.revision < metadata.learningRevision) return;
      // A deleted message cannot contribute new learned memory.
      const source = await client.query("SELECT 1 FROM agent.mastra_messages WHERE id = $1 AND thread_id = $2 AND role = 'user'", [job.messageId, job.threadId]);
      if (!source.rowCount) return;
      const next = [metadata.learned, `- ${note}`].filter(Boolean).join("\n");
      if (metadata.learned.split("\n").includes(`- ${note}`)) return;
      if (!workingMemoryContentSchema.safeParse(next).success) {
        metadata.automatic = false;
        metadata.capacityReached = true;
      } else metadata.learned = next;
      metadata.revision++;
      if (!metadata.capacityReached) metadata.learnedRevision = metadata.revision;
      await this.saveProfile(client, identity.userId, metadata);
    });
  }
  async enqueueLearned(identity: Identity, threadId: string, messageId: string, revision: number) {
    await this.scoped(identity, async (client) => {
      const source = await client.query(`SELECT 1 FROM agent.mastra_messages m JOIN agent.mastra_threads t ON t.id = m.thread_id
        WHERE m.id = $1 AND t.id = $2 AND t."resourceId" = $3 AND m.role = 'user'`, [messageId, threadId, identity.userId]);
      if (!source.rowCount) return;
      await enqueueJob(drizzle({ client }), schema, `chat-memory:working:${messageId}`, "chat-memory",
        identity.userId, `chat:${threadId}`, { threadId, ownerUserId: identity.userId, memoryKind: "working", messageId, revision }, new Date(), false);
    });
  }
  async selectMeeting(identity: Identity, threadId: string, meetingId: string | null) {
    await this.scoped(identity, async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [threadId]);
      const busy = await client.query("SELECT 1 FROM agent.ai_thread_runs WHERE thread_id = $1 AND expires_at > now()", [threadId]);
      if (busy.rowCount) throw new RequestError(409, "ai_thread_busy");
      const result = await client.query(`UPDATE agent.mastra_threads SET metadata = metadata || jsonb_build_object('meetingId', $2::text)
        WHERE id = $1 AND "resourceId" = $3 RETURNING id`, [threadId, meetingId, identity.userId]);
      if (!result.rowCount) throw new RequestError(404, "ai_thread_not_found");
      const tx = drizzle({ client });
      if (meetingId) await enqueueJob(tx, schema, `chat-memory:live:${threadId}`, "chat-memory", identity.userId,
        `chat:${threadId}`, { threadId, ownerUserId: identity.userId, memoryKind: "live", revision: 0 });
      else await cancelJobs(tx, schema, eq(schema.backgroundJob.dedupeKey, `chat-memory:live:${threadId}`));
    });
  }

  async selection(identity: Identity, threadId: string) {
    return this.scoped(identity, async (client) => {
      const { rows: [row] } = await client.query<{ metadata: { workspaceId: string; meetingId?: string | null } }>(
        'SELECT metadata FROM agent.mastra_threads WHERE id = $1 AND "resourceId" = $2', [threadId, identity.userId]);
      if (!row) throw new RequestError(404, "ai_thread_not_found");
      return { workspaceId: row.metadata.workspaceId, meetingId: row.metadata.meetingId ?? null };
    });
  }
  async snapshot(identity: Identity, meetingId: string): Promise<LiveSnapshot | null> {
    return this.scoped(identity, async (client) => {
      const { rows: [row] } = await client.query<{ snapshot: unknown }>("SELECT snapshot FROM agent.live_contexts WHERE meeting_id = $1", [meetingId]);
      // Snapshots are rebuildable; an older projection may omit coverage or attribution.
      return liveSnapshotSchema.safeParse(row?.snapshot).data ?? null;
    });
  }
  async claimMeeting(identity: Identity, meetingId: string) {
    return this.scoped(identity, async (client) => {
      await client.query("INSERT INTO agent.live_contexts (meeting_id) VALUES ($1) ON CONFLICT DO NOTHING", [meetingId]);
      const lease = uuidV7();
      const result = await client.query(`UPDATE agent.live_contexts SET lease = $2, lease_until = now() + interval '2 minutes'
        WHERE meeting_id = $1 AND (lease_until IS NULL OR lease_until < now()) RETURNING meeting_id`, [meetingId, lease]);
      return result.rowCount ? lease : null;
    });
  }
  async saveSnapshot(identity: Identity, meetingId: string, lease: string, snapshot: LiveSnapshot | null, release = true, queue?: BackgroundJob) {
    await this.scoped(identity, async (client) => {
      if (queue && !await lockJob(drizzle({ client }), schema, queue)) return;
      await client.query(`UPDATE agent.live_contexts SET snapshot = $3,
        lease_until = CASE WHEN $4 THEN NULL ELSE lease_until END WHERE meeting_id = $1 AND lease = $2 AND lease_until > now()`,
      [meetingId, lease, snapshot ? JSON.stringify(snapshot) : null, release]);
    });
  }

  async releaseMeeting(identity: Identity, meetingId: string, lease: string) {
    await this.scoped(identity, (client) => client.query("UPDATE agent.live_contexts SET lease_until = NULL WHERE meeting_id = $1 AND lease = $2", [meetingId, lease]));
  }
  async due() {
    const rows = await drizzle({ client: this.pool }).select().from(schema.backgroundJob).where(and(eq(schema.backgroundJob.kind, "chat-memory"),
      eq(schema.backgroundJob.status, "pending"))).limit(20);
    return rows.map((row) => ({ id: row.dedupeKey.slice("chat-memory:".length), userId: row.owner }));
  }
  async scheduleLive(identity: Identity, threadId: string) {
    await this.scoped(identity, async (client) => {
      const thread = await client.query('SELECT 1 FROM agent.mastra_threads WHERE id = $1 AND "resourceId" = $2', [threadId, identity.userId]);
      if (!thread.rowCount) throw new RequestError(404, "ai_thread_not_found");
      await enqueueJob(drizzle({ client }), schema, `chat-memory:live:${threadId}`, "chat-memory",
        identity.userId, `chat:${threadId}`, { threadId, ownerUserId: identity.userId, memoryKind: "live", revision: 0 }, new Date(), false);
    });
  }
  async claim(identity: Identity, id: string, supplied?: BackgroundJob): Promise<MemoryJob | undefined> {
    const job = supplied ?? await createJobStore(drizzle({ client: this.pool }), true, defaultJobLimits).claim(["chat-memory"], [`chat-memory:${id}`]);
    if (!job || job.owner !== identity.userId) return undefined;
    return this.scoped(identity, async (client) => {
      if (!await lockJob(drizzle({ client }), schema, job)) return undefined;
      const thread = await client.query('SELECT 1 FROM agent.mastra_threads WHERE id = $1 AND "resourceId" = $2', [job.payload.threadId, identity.userId]);
      if (!thread.rowCount) return undefined;
      return { queue: job, id, userId: identity.userId, threadId: job.payload.threadId!, kind: job.payload.memoryKind!,
        messageId: job.payload.messageId ?? null, revision: job.payload.revision!, lease: job.lease!, attempts: Math.max(0, job.attempts - 1) };
    });
  }
  async finish(identity: Identity, job: MemoryJob, delaySeconds?: number, failed = false) {
    if (!job.queue) return undefined;
    await this.scoped(identity, (client) => settleJob(drizzle({ client }), schema, job.queue!, delaySeconds === undefined ? undefined : {
      status: "pending", availableAt: new Date(Date.now() + delaySeconds * 1000), attempts: failed ? job.attempts + 1 : 0,
    }));
    return delaySeconds;
  }
  async message(identity: Identity, threadId: string, messageId: string) {
    return this.scoped(identity, async (client) => {
      const { rows: [row] } = await client.query<{ content: string }>("SELECT content FROM agent.mastra_messages WHERE id = $1 AND thread_id = $2 AND role = 'user'", [messageId, threadId]);
      if (!row) return null;
      const content = JSON.parse(row.content) as { parts: Array<{ type: string; text?: string }> };
      return content.parts.filter((p) => p.type === "text").map((p) => p.text ?? "").join("");
    });
  }
}
