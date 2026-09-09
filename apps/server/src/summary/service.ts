import { z } from "zod";
import { normalizeSummaryDetail, outputLanguageSchema } from "../account-settings-model";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettingsStore } from "../account-settings";
import type { Identity } from "../auth/identity";
import { RequestError } from "../storage/upload";
import type { MeetingSyncStore } from "../sync/types";
import { SummaryError, summaryDetailSchema, summaryInputSchema, type SummaryJob, type SummaryMethod } from "./model";

export const summaryStartSchema = z.union([
  z.object({ id: z.uuidv7(), input: summaryInputSchema, model: z.string().trim().min(1).max(200),
    detailLevel: summaryDetailSchema, summaryLanguage: outputLanguageSchema }).strict(),
  // Existing clients may omit the explicit input; already accepted jobs keep their original settings.
  z.object({ id: z.uuidv7(), detail: summaryDetailSchema.optional(), outputLanguage: outputLanguageSchema.optional() }).strict(),
]);
export type SummaryRequest = z.infer<typeof summaryStartSchema>;

export class SummaryService {
  constructor(private readonly store: MeetingSyncStore, private readonly settings: AccountSettingsStore,
    readonly methods: readonly SummaryMethod[]) {}

  async status(identity: Identity, vaultId: string, meetingId: string, id?: string): Promise<SummaryJob | null> {
    return this.store.withIdentity(identity, async (scoped) => {
      if ((await scoped.getVault(vaultId))?.role !== "owner" || !await scoped.getMeeting(vaultId, meetingId)) {
        throw new RequestError(404, "summary_meeting_unavailable");
      }
      return scoped.getSummaryJob(vaultId, meetingId, id);
    });
  }
  async cancel(identity: Identity, vaultId: string, meetingId: string, id: string): Promise<SummaryJob> {
    if (identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      if ((await scoped.getVault(vaultId))?.role !== "owner" || !await scoped.getMeeting(vaultId, meetingId)) {
        throw new RequestError(404, "summary_meeting_unavailable");
      }
      const job = await scoped.getSummaryJob(vaultId, meetingId, id);
      if (!job) throw new RequestError(404, "summary_job_unavailable");
      return await scoped.cancelSummaryJob(vaultId, meetingId, id) ?? job;
    });
  }

  async retry(identity: Identity, vaultId: string, meetingId: string, previousId: string, body: unknown): Promise<SummaryJob> {
    if (identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    const parsed = z.object({ id: z.uuidv7() }).strict().safeParse(body);
    if (!parsed.success) throw new RequestError(400, "invalid_summary_request");
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      if ((await scoped.getVault(vaultId))?.role !== "owner" || !await scoped.getMeeting(vaultId, meetingId)) {
        throw new RequestError(404, "summary_meeting_unavailable");
      }
      const requestHash = JSON.stringify({ vaultId, meetingId, retryOf: previousId });
      const existing = await scoped.getSummaryJob(vaultId, meetingId, parsed.data.id);
      if (existing) {
        if (existing.requestHash !== requestHash) throw new RequestError(409, "summary_id_reused");
        return existing;
      }
      const previous = await scoped.getSummaryJob(vaultId, meetingId, previousId);
      if (!previous || !["failed", "cancelled"].includes(previous.status)) throw new RequestError(409, "summary_job_not_retryable");
      const current = await scoped.getSummaryJob(vaultId, meetingId);
      if (current && ["pending", "processing"].includes(current.status)) throw new RequestError(409, "summary_already_running");
      const now = new Date();
      const job: SummaryJob = { ...previous, id: parsed.data.id, requestHash, status: "pending", attempts: 0,
        createdAt: now, availableAt: now, claimedAt: null, leaseExpiresAt: null, lastErrorCode: null,
        stage: previous.transcriptResult || previous.method === "transcript" ? "summarizing"
          : previous.input?.type === "recording" && previous.input.transcriptionModel ? "transcribing" : "generating" };
      await scoped.insertSummaryJob(job);
      return job;
    });
  }

  async start(identity: Identity, vaultId: string, meetingId: string, body: unknown): Promise<SummaryJob> {
    if (identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    const parsed = summaryStartSchema.safeParse(body);
    if (!parsed.success) throw new RequestError(400, "invalid_summary_request");
    const settings = await this.settings.get(identity.userId) ?? DEFAULT_ACCOUNT_SETTINGS;
    const request = parsed.data;
    const input = "input" in request ? request.input : undefined;
    const requestHash = JSON.stringify({ vaultId, meetingId,
      ...("input" in request ? { input: request.input, model: request.model, detailLevel: request.detailLevel } : { detail: request.detail ?? null }),
      ...("summaryLanguage" in request ? { summaryLanguage: request.summaryLanguage } : request.outputLanguage === undefined ? {} : { outputLanguage: request.outputLanguage }) });
    // Authorize and recover accepted requests before any provider I/O. Recheck under the lock before insertion.
    const accepted = await this.status(identity, vaultId, meetingId, request.id);
    if (accepted) {
      if (normalizeSummaryRequestHash(accepted.requestHash) !== requestHash) throw new RequestError(409, "summary_id_reused");
      return accepted;
    }
    if (!input && settings.summary.method === "cloudTranscription") throw new RequestError(400, "summary_input_required");
    const methodID = (input?.type === "recording" ? "audio" : input?.type) ?? (settings.summary.method === "cloudTranscription" ? "audio" : settings.summary.method);
    const method = this.methods.find((method) => method.id === methodID);
    if (!method) throw new RequestError(400, "summary_method_unavailable");
    const captured = method.captureSettings(settings, "detailLevel" in request ? request.detailLevel : request.detail);
    if (input?.type === "recording" && input.transcriptionModel) {
      captured.model = settings.summary.methodSettings.transcript.model;
      captured.reasoningEffort = settings.summary.methodSettings.transcript.reasoningEffort;
    }
    if ("model" in request) captured.model = request.model;
    try { await method.validateSettings?.(captured, input); }
    catch (error) {
      if (error instanceof SummaryError) throw new RequestError(error.retryable ? 503 : 400, error.code);
      throw error;
    }
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      if ((await scoped.getVault(vaultId))?.role !== "owner") throw new RequestError(404, "summary_meeting_unavailable");
      const meeting = await scoped.getMeeting(vaultId, meetingId);
      if (!meeting) throw new RequestError(404, "summary_meeting_unavailable");
      const previous = await scoped.getSummaryJob(vaultId, meetingId, parsed.data.id);
      if (previous) {
        if (normalizeSummaryRequestHash(previous.requestHash) !== requestHash) throw new RequestError(409, "summary_id_reused");
        return previous;
      }
      const current = await scoped.getSummaryJob(vaultId, meetingId);
      if (current && ["pending", "processing"].includes(current.status)) throw new RequestError(409, "summary_already_running");
      let inputVersion: string;
      try {
        inputVersion = await method.version(scoped, vaultId, meetingId, input);
      }
      catch (error) {
        if (error instanceof SummaryError) throw new RequestError(error.retryable ? 503 : 400, error.code);
        throw error;
      }
      const now = new Date();
      const job: SummaryJob = {
        id: parsed.data.id, vaultId, meetingId, ownerUserId: identity.userId,
        method: methodID, settings: captured,
        input: input ?? null, transcriptRevision: meeting.transcriptRevision ?? 0,
        stage: methodID === "transcript" ? "summarizing" : input?.type === "recording" && input.transcriptionModel ? "transcribing" : "generating",
        transcriptResult: null,
        outputLanguage: "summaryLanguage" in request ? request.summaryLanguage : request.outputLanguage ?? settings.outputLanguage, requestHash, summaryRevision: meeting.summaryRevision ?? 0,
        inputVersion,
        status: "pending", attempts: 0, createdAt: now, availableAt: now, claimedAt: null, leaseExpiresAt: null, lastErrorCode: null,
      };
      await scoped.insertSummaryJob(job);
      return job;
    });
  }
}
export function summaryJobResponse(job: SummaryJob | null) {
  if (!job) return null;
  const { id, method, input, stage, transcriptResult, settings, outputLanguage, status, attempts, createdAt, lastErrorCode } = job;
  return { id, method, input, stage, transcriptResult, settings, outputLanguage, status, attempts, createdAt, error: lastErrorCode };
}

// Old accepted requests keep their identity when the detail vocabulary changes.
function normalizeSummaryRequestHash(hash: string): string {
  const value: unknown = JSON.parse(hash);
  if (!value || typeof value !== "object" || !("detail" in value)) return hash;
  if (typeof value.detail === "string") value.detail = normalizeSummaryDetail(value.detail);
  return JSON.stringify(value);
}
