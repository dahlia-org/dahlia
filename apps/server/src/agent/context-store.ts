import type { Pool, PoolClient } from "pg";
import type { Identity } from "../auth/identity";
import { uuidV7 } from "../id";
import { RequestError } from "../storage/upload";
import { withIdentityTransaction } from "./history";
import { emptyPreferences, preferencesSchema, liveSnapshotSchema,
  type Preferences, type PreferenceSettings, type LiveSnapshot } from "./context-model";

type ProfileMetadata = { revision: number; manualRevision?: number; automatic: boolean; locked: Array<keyof Preferences>;
  sources: Partial<Record<keyof Preferences, { threadId: string; messageId: string }>> };
export interface MemoryJob { id: string; userId: string; threadId: string; kind: "preference" | "live";
  messageId: string | null; revision: number; lease: string; attempts: number }
const defaults = (): ProfileMetadata => ({ revision: 0, automatic: true, locked: [], sources: {} });

export class ChatMemoryStore {
  constructor(private readonly pool: Pool) {}
  private scoped<T>(identity: Identity, action: (client: PoolClient) => Promise<T>) {
    return withIdentityTransaction(this.pool, identity, action);
  }
  private async profile(client: PoolClient, userId: string) {
    const { rows: [row] } = await client.query<{ workingMemory: string | null; metadata: { preferences?: ProfileMetadata } | null }>(
      'SELECT "workingMemory", metadata FROM agent.mastra_resources WHERE id = $1', [userId]);
    return { preferences: preferencesSchema.parse(row?.workingMemory ? JSON.parse(row.workingMemory) : emptyPreferences),
      metadata: row?.metadata?.preferences ?? defaults() };
  }
  private async saveProfile(client: PoolClient, userId: string, preferences: Preferences, metadata: ProfileMetadata) {
    await client.query(`INSERT INTO agent.mastra_resources (id, "workingMemory", metadata, "createdAt", "updatedAt", "createdAtZ", "updatedAtZ")
      VALUES ($1, $2, $3, now(), now(), now(), now()) ON CONFLICT (id) DO UPDATE SET
      "workingMemory" = EXCLUDED."workingMemory", metadata = COALESCE(agent.mastra_resources.metadata, '{}'::jsonb) || EXCLUDED.metadata,
      "updatedAt" = now(), "updatedAtZ" = now()`, [userId, JSON.stringify(preferences), JSON.stringify({ preferences: metadata })]);
  }
  async settings(identity: Identity): Promise<PreferenceSettings> {
    return this.scoped(identity, async (client) => {
      const { preferences, metadata } = await this.profile(client, identity.userId);
      return { preferences, revision: metadata.revision, automatic: metadata.automatic };
    });
  }
  async editSettings(identity: Identity, input: PreferenceSettings) {
    return this.scoped(identity, async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 1))", [identity.userId]);
      const { preferences, metadata } = await this.profile(client, identity.userId);
      if (input.revision !== metadata.revision) throw new RequestError(409, "memory_revision_conflict");
      for (const key of Object.keys(preferences) as Array<keyof Preferences>) {
        if (preferences[key] !== input.preferences[key]) {
          if (!metadata.locked.includes(key)) metadata.locked.push(key);
          delete metadata.sources[key];
        }
      }
      metadata.automatic = input.automatic;
      metadata.revision++;
      metadata.manualRevision = metadata.revision;
      await this.saveProfile(client, identity.userId, input.preferences, metadata);
      return { ...input, revision: metadata.revision };
    });
  }
  async applyPreferences(identity: Identity, job: MemoryJob, patch: Partial<Preferences>) {
    return this.scoped(identity, async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 1))", [identity.userId]);
      const { preferences, metadata } = await this.profile(client, identity.userId);
      if (!metadata.automatic || job.revision < (metadata.manualRevision ?? 0)) return;
      // A deleted thread/message must not resurrect a preference after extraction completes.
      const source = await client.query("SELECT 1 FROM agent.mastra_messages WHERE id = $1 AND thread_id = $2 AND role = 'user'", [job.messageId, job.threadId]);
      if (!source.rowCount) return;
      // Queue delivery order is not conversation order; an older request must not overwrite a newer one.
      const newer = await client.query<{ id: string }>(`SELECT id FROM agent.mastra_messages
        WHERE id = ANY($1::text[]) AND (COALESCE("createdAtZ", "createdAt"), id) >=
          (SELECT COALESCE("createdAtZ", "createdAt"), id FROM agent.mastra_messages WHERE id = $2)`,
      [Object.values(metadata.sources).map((source) => source.messageId), job.messageId]);
      const newerSourceIds = new Set(newer.rows.map((row) => row.id));
      let changed = false;
      for (const key of Object.keys(patch) as Array<keyof Preferences>) {
        if (metadata.locked.includes(key) || patch[key] == null) continue;
        const previous = metadata.sources[key];
        if (previous && newerSourceIds.has(previous.messageId)) continue;
        Object.assign(preferences, { [key]: patch[key] });
        metadata.sources[key] = { threadId: job.threadId, messageId: job.messageId! };
        changed = true;
      }
      if (changed) { metadata.revision++; await this.saveProfile(client, identity.userId, preferences, metadata); }
    });
  }
  async enqueuePreferences(identity: Identity, threadId: string, messageId: string, revision: number) {
    await this.scoped(identity, (client) => client.query(`INSERT INTO agent.memory_jobs
      (id, user_id, thread_id, kind, message_id, revision) VALUES ($1, $2, $3, 'preference', $4, $5) ON CONFLICT DO NOTHING`,
    [`preference:${messageId}`, identity.userId, threadId, messageId, revision]));
  }
  async selectMeeting(identity: Identity, threadId: string, meetingId: string | null) {
    await this.scoped(identity, async (client) => {
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [threadId]);
      const busy = await client.query("SELECT 1 FROM agent.ai_thread_runs WHERE thread_id = $1 AND expires_at > now()", [threadId]);
      if (busy.rowCount) throw new RequestError(409, "ai_thread_busy");
      const result = await client.query(`UPDATE agent.mastra_threads SET metadata = metadata || jsonb_build_object('meetingId', $2::text)
        WHERE id = $1 AND "resourceId" = $3 RETURNING id`, [threadId, meetingId, identity.userId]);
      if (!result.rowCount) throw new RequestError(404, "ai_thread_not_found");
      await client.query("DELETE FROM agent.memory_jobs WHERE id = $1", [`live:${threadId}`]);
      if (meetingId) await client.query(`INSERT INTO agent.memory_jobs (id, user_id, thread_id, kind, revision)
        VALUES ($1, $2, $3, 'live', 0)`, [`live:${threadId}`, identity.userId, threadId]);
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
  async saveSnapshot(identity: Identity, meetingId: string, lease: string, snapshot: LiveSnapshot | null, release = true) {
    await this.scoped(identity, (client) => client.query(`UPDATE agent.live_contexts SET snapshot = $3,
      lease_until = CASE WHEN $4 THEN NULL ELSE lease_until END WHERE meeting_id = $1 AND lease = $2`,
    [meetingId, lease, snapshot ? JSON.stringify(snapshot) : null, release]));
  }
  async releaseMeeting(identity: Identity, meetingId: string, lease: string) {
    await this.scoped(identity, (client) => client.query("UPDATE agent.live_contexts SET lease_until = NULL WHERE meeting_id = $1 AND lease = $2", [meetingId, lease]));
  }
  async due() {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("SELECT set_config('app.maintenance', 'agent-memory', true)");
      const result = await client.query<{ id: string; userId: string }>(`SELECT id, user_id AS "userId" FROM agent.memory_jobs
        WHERE available_at <= now() AND (lease_until IS NULL OR lease_until < now()) ORDER BY available_at, id LIMIT 20`);
      await client.query("COMMIT");
      return result.rows;
    } catch (error) { await client.query("ROLLBACK"); throw error; }
    finally { client.release(); }
  }
  async scheduleLive(identity: Identity, threadId: string) {
    await this.scoped(identity, (client) => client.query(`INSERT INTO agent.memory_jobs (id, user_id, thread_id, kind, revision)
      VALUES ($1, $2, $3, 'live', 0) ON CONFLICT DO NOTHING`, [`live:${threadId}`, identity.userId, threadId]));
  }
  async claim(identity: Identity, id: string): Promise<MemoryJob | undefined> {
    return this.scoped(identity, async (client) => (await client.query<MemoryJob>(`UPDATE agent.memory_jobs
      SET lease = $2, lease_until = now() + interval '2 minutes' WHERE id = $1 AND available_at <= now()
      AND (lease_until IS NULL OR lease_until < now()) RETURNING id, user_id AS "userId", thread_id AS "threadId", kind,
      message_id AS "messageId", revision, lease, attempts`, [id, uuidV7()])).rows[0]);
  }
  async finish(identity: Identity, job: MemoryJob, delaySeconds?: number, failed = false) {
    const result = await this.scoped(identity, (client) => {
      if (delaySeconds === undefined) {
        return client.query("DELETE FROM agent.memory_jobs WHERE id = $1 AND lease = $2", [job.id, job.lease]);
      }
      return client.query(`UPDATE agent.memory_jobs SET lease_until = NULL, available_at = now() + $3 * interval '1 second',
          attempts = CASE WHEN $4 THEN attempts + 1 ELSE 0 END WHERE id = $1 AND lease = $2`, [job.id, job.lease, delaySeconds, failed]);
    });
    return result.rowCount && delaySeconds !== undefined ? delaySeconds : undefined;
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
