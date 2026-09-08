import { z } from "zod";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettingsStore } from "../account-settings";
import type { Identity } from "../auth/identity";
import { RequestError } from "../storage/upload";
import type { MeetingSyncStore } from "../sync/types";
import { summaryDetailSchema, type SummaryJob, type SummaryMethod } from "./model";

export const summaryStartSchema = z.object({ id: z.uuidv7(), detail: summaryDetailSchema.optional() }).strict();
export class SummaryService {
  constructor(private readonly store: MeetingSyncStore, private readonly settings: AccountSettingsStore,
    readonly methods: readonly SummaryMethod[]) {}

  async status(identity: Identity, vaultId: string, meetingId: string): Promise<SummaryJob | null> {
    return this.store.withIdentity(identity, async (scoped) => {
      if ((await scoped.getVault(vaultId))?.role !== "owner" || !await scoped.getMeeting(vaultId, meetingId)) {
        throw new RequestError(404, "summary_meeting_unavailable");
      }
      return scoped.getSummaryJob(vaultId, meetingId);
    });
  }
  async start(identity: Identity, vaultId: string, meetingId: string, body: unknown): Promise<SummaryJob> {
    if (identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    const parsed = summaryStartSchema.safeParse(body);
    if (!parsed.success) throw new RequestError(400, "invalid_summary_request");
    const settings = await this.settings.get(identity.userId) ?? DEFAULT_ACCOUNT_SETTINGS;
    const method = this.methods.find((method) => method.id === settings.summary.method);
    if (!method) throw new RequestError(400, "summary_method_unavailable");
    const requestHash = JSON.stringify({ vaultId, meetingId, detail: parsed.data.detail ?? null });
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      if ((await scoped.getVault(vaultId))?.role !== "owner") throw new RequestError(404, "summary_meeting_unavailable");
      const meeting = await scoped.getMeeting(vaultId, meetingId);
      if (!meeting) throw new RequestError(404, "summary_meeting_unavailable");
      const previous = await scoped.getSummaryJob(vaultId, meetingId, parsed.data.id);
      if (previous) {
        if (previous.requestHash !== requestHash) throw new RequestError(409, "summary_id_reused");
        return previous;
      }
      const current = await scoped.getSummaryJob(vaultId, meetingId);
      if (current && ["pending", "processing"].includes(current.status)) throw new RequestError(409, "summary_already_running");
      const now = new Date();
      const job: SummaryJob = {
        id: parsed.data.id, vaultId, meetingId, ownerUserId: identity.userId,
        method: settings.summary.method, settings: method.captureSettings(settings, parsed.data.detail),
        outputLanguage: settings.outputLanguage, requestHash, summaryRevision: meeting.summaryRevision ?? 0,
        inputVersion: await method.version(scoped, vaultId, meetingId),
        status: "pending", attempts: 0, createdAt: now, availableAt: now, claimedAt: null, leaseExpiresAt: null, lastErrorCode: null,
      };
      await scoped.insertSummaryJob(job);
      return job;
    });
  }
}
export function summaryJobResponse(job: SummaryJob | null) {
  if (!job) return null;
  const { id, method, settings, outputLanguage, status, attempts, createdAt, lastErrorCode } = job;
  return { id, method, settings, outputLanguage, status, attempts, createdAt, error: lastErrorCode };
}
