import { describe, expect, it, vi } from "vitest";
import { emptyPreferences, preferenceSettingsSchema, validatedPreferences, emptyLiveNotes, liveSnapshotSchema, type LiveSnapshot } from "../src/agent/context-model";
import { ChatMemoryService } from "../src/agent/context-service";
import type { ChatMemoryStore } from "../src/agent/context-store";
import type { MeetingSyncService } from "../src/sync/service";
import { RequestError } from "../src/storage/upload";
import { uuidV7 } from "../src/id";
import { transcriptCheckpoint } from "../src/sync/transcript-checkpoint";

const userId = uuidV7(), workspaceId = uuidV7(), meetingId = uuidV7(), threadId = uuidV7(), segmentId = uuidV7();
const identity = { userId, source: "header" as const };
const signal = new AbortController().signal;

describe("private preference boundaries", () => {
  it("retains persistent preferences and nuanced explanation style, but rejects quoted, one-off and business text", () => {
    const extract = (key: "language" | "explanation", value: string, evidence: string) => ({ candidates: [{ key, value, evidence }] });
    expect(validatedPreferences("今後は日本語で回答してください。", extract("language", "ja", "今後は日本語で回答してください。"))).toEqual({ language: "ja" });
    const value = "専門用語は初出時に説明してほしい";
    expect(validatedPreferences(`今後は${value}。`, extract("explanation", value, `今後は${value}。`))).toEqual({ explanation: value });
    for (const text of ["今回だけ日本語で回答してください。", "引用：『今後は日本語で回答してください。』", "> 今後は日本語で回答してください。", "```\n今後は日本語で回答してください。\n```", "いつも英語です"]) {
      expect(validatedPreferences(text, extract("language", "ja", "今後は日本語で回答してください。"))).toEqual({});
    }
    expect(validatedPreferences("今後はA社の契約を優先する", extract("explanation", "A社の契約を優先する", "今後はA社の契約を優先する"))).toEqual({});
    expect(validatedPreferences("I always prefer Japanese", extract("language", "company-secret", "I always prefer Japanese"))).toEqual({});
    expect(preferenceSettingsSchema.safeParse({ revision: 0, automatic: true, preferences: { ...emptyPreferences, explanation: "x".repeat(241) } }).success).toBe(false);
  });
});

function fixture() {
  const job = { id: `live:${threadId}`, userId, threadId, kind: "live", revision: 0, lease: "job-lease", attempts: 0, messageId: null };
  const snapshot = { after: "old", truncated: false, notes: { ...emptyLiveNotes, topics: [{ text: "OLD", segmentIds: [segmentId] }] }, recent: [], updatedAt: new Date().toISOString(), processedThrough: null };
  const store = { selection: vi.fn().mockResolvedValue({ workspaceId, meetingId }), snapshot: vi.fn().mockResolvedValue(snapshot),
    selectMeeting: vi.fn(), claim: vi.fn().mockResolvedValue(job), claimMeeting: vi.fn().mockResolvedValue("lease"),
    saveSnapshot: vi.fn(), releaseMeeting: vi.fn(), finish: vi.fn() };
  const page = { items: [{ segmentId, text: "NEW", startedAt: new Date() }], next_after: "new" };
  const sync = { getWorkspace: vi.fn().mockResolvedValue({ encryption: "none" }), getMeeting: vi.fn().mockResolvedValue({ isRecording: true }),
    listTranscript: vi.fn().mockResolvedValue(page) };
  const generate = vi.fn().mockResolvedValue({ ...emptyLiveNotes, topics: [{ text: "NEW", segmentIds: [segmentId] }] });
  const service = new ChatMemoryService(store as unknown as ChatMemoryStore, sync as unknown as MeetingSyncService, generate);
  return { service, store, sync, generate, snapshot, job };
}

describe("live meeting context", () => {
  it("continues without a deleted selection but still rejects revoked Workspace access", async () => {
    const { service, sync, store } = fixture();
    sync.getMeeting.mockResolvedValue(null);
    expect(await service.context(identity, threadId, signal, true)).toEqual({
      status: { meetingId, status: "unavailable", updatedAt: null, processedThrough: null }, context: "",
    });
    expect(store.snapshot).not.toHaveBeenCalled();
    sync.getWorkspace.mockResolvedValue(null);
    await expect(service.context(identity, threadId, signal)).rejects.toMatchObject({ code: "workspace_not_found" });
    sync.getWorkspace.mockResolvedValue({ encryption: "server" });
    await expect(service.context(identity, threadId, signal)).rejects.toMatchObject({ code: "ai_history_encrypted_workspace_unsupported" });
  });
  it("preserves attribution and incomplete coverage across generation, saved excerpts and later batches", async () => {
    const { service, store, sync, generate, job } = fixture();
    let saved: LiveSnapshot | null = null;
    store.snapshot.mockImplementation(async () => saved);
    store.saveSnapshot.mockImplementation((_identity: unknown, _meeting: unknown, _lease: unknown, value: unknown) => {
      saved = value === null ? null : liveSnapshotSchema.parse(value);
    });
    const speaker = { segmentId, startedAt: new Date(), speakerLabel: "Alice", audioSource: "mic" };
    sync.listTranscript.mockResolvedValue({ items: [{ ...speaker, text: "x".repeat(4000) + "Decision reversed" }], next_after: "long" });
    const before = JSON.parse((await service.context(identity, threadId, signal)).context) as { truncated: boolean; unprocessed: unknown[] };
    expect(before.truncated).toBe(true);
    expect(before.unprocessed).toEqual([{ ...speaker, startedAt: speaker.startedAt.toISOString(), text: "x".repeat(4000), truncated: true }]);
    await service.step(job.id, userId, signal);
    expect(JSON.parse(String(generate.mock.calls[0]?.[1]))).toMatchObject({ truncated: true, segments: before.unprocessed });
    expect(saved).toMatchObject({ truncated: true, recent: before.unprocessed });
    // The coverage flag survives even when the truncated excerpt leaves the bounded recent window.
    sync.listTranscript.mockResolvedValue({ items: Array.from({ length: 16 }, () => ({ ...speaker, text: "Short", speakerLabel: "Bob", audioSource: "system" })), next_after: "short" });
    await service.step(job.id, userId, signal);
    await service.step(job.id, userId, signal);
    expect(saved).toMatchObject({ truncated: true });
    expect(liveSnapshotSchema.parse(saved).recent).toHaveLength(20);
    expect(liveSnapshotSchema.parse(saved).recent.every((segment) => !segment.truncated && segment.speakerLabel === "Bob")).toBe(true);
    sync.listTranscript.mockResolvedValue({ items: [], next_after: "short" });
    expect(JSON.parse((await service.context(identity, threadId, signal)).context)).toMatchObject({ truncated: true });
    // A canonical correction rebuilds the projection and resets coverage from the corrected source.
    sync.listTranscript.mockRejectedValueOnce(new RequestError(409, "transcript_changed_refetch_without_after"))
      .mockResolvedValue({ items: [{ ...speaker, text: "x".repeat(4000), speakerLabel: null, audioSource: null }], next_after: "corrected" });
    await service.step(job.id, userId, signal);
    expect(saved).toMatchObject({ truncated: false, recent: [{ truncated: false, speakerLabel: null, audioSource: null }] });
  });
  it("rebuilds transferred meeting checkpoints for both reads and background jobs", async () => {
    const { service, store, sync, generate, snapshot, job } = fixture();
    const records = [{ segmentId, text: "NEW", startedAt: new Date() }];
    const oldPage = await transcriptCheckpoint(uuidV7(), meetingId, "v1", records, undefined, 0, 16);
    store.snapshot.mockResolvedValue({ ...snapshot, after: oldPage.next_after });
    sync.listTranscript.mockImplementation(async (...[, workspace, meeting, , options]: Parameters<MeetingSyncService["listTranscript"]>) => {
      const page = await transcriptCheckpoint(workspace, meeting, "v1", records, options?.after, 0, 16);
      return page;
    });
    expect((await service.context(identity, threadId, signal)).context).not.toContain("OLD");
    await service.step(job.id, userId, signal);
    expect(generate.mock.calls[0]?.[1]).not.toContain("OLD");
    expect(store.saveSnapshot).toHaveBeenCalledWith(expect.anything(), meetingId, "lease", null, false);
    expect(store.saveSnapshot).toHaveBeenLastCalledWith(expect.anything(), meetingId, "lease", expect.objectContaining({ notes: { ...emptyLiveNotes, topics: [{ text: "NEW", segmentIds: [segmentId] }] } }));
  });
  it("does not turn authorization failures into checkpoint rebuilds or continue unclaimed deliveries", async () => {
    const { service, store, sync } = fixture();
    sync.listTranscript.mockRejectedValue(new RequestError(403, "forbidden"));
    await expect(service.context(identity, threadId, signal)).rejects.toMatchObject({ status: 403 });
    expect(sync.listTranscript).toHaveBeenCalledTimes(1);
    store.claim.mockResolvedValue(undefined);
    expect(await service.step("duplicate", userId, signal)).toBeUndefined();
    expect(store.finish).not.toHaveBeenCalled();
  });
  it("rejects a meeting outside the authorized Workspace before persisting selection", async () => {
    const { service, store, sync } = fixture(); sync.getMeeting.mockResolvedValue(null);
    await expect(service.select(identity, threadId, meetingId)).rejects.toMatchObject({ code: "meeting_not_found" });
    expect(store.selectMeeting).not.toHaveBeenCalled();
  });
  it("rebuilds changed transcripts and never sends stale notes to the generator or answer", async () => {
    const { service, store, sync, generate } = fixture();
    sync.listTranscript.mockRejectedValueOnce(new RequestError(409, "transcript_changed_refetch_without_after"));
    const result = await service.context(identity, threadId, signal);
    expect(result.context).not.toContain("OLD"); expect(result.status.status).toBe("pending");
    sync.listTranscript.mockRejectedValueOnce(new RequestError(409, "transcript_changed_refetch_without_after"));
    await service.step(`live:${threadId}`, userId, signal);
    expect(generate.mock.calls[0]?.[1]).not.toContain("OLD");
    expect(store.saveSnapshot).toHaveBeenCalledWith(expect.anything(), meetingId, "lease", null, false);
    expect(store.saveSnapshot).toHaveBeenCalledWith(expect.anything(), meetingId, "lease", expect.objectContaining({ after: "new" }));
  });
  it("reuses unchanged context without model calls and stops scheduling when the meeting ends", async () => {
    const { service, store, sync, generate, job } = fixture();
    sync.listTranscript.mockResolvedValue({ items: [], next_after: "old" }); sync.getMeeting.mockResolvedValue({ isRecording: false });
    await service.step(job.id, userId, signal);
    expect(generate).not.toHaveBeenCalled(); expect(store.finish).toHaveBeenCalledWith(expect.anything(), job, undefined);
  });
  it("does not publish after a correction during generation; retries without losing canonical data", async () => {
    const { service, store, sync, job } = fixture();
    sync.listTranscript.mockResolvedValueOnce({ items: [{ segmentId, text: "NEW", startedAt: new Date() }], next_after: "new" })
      .mockRejectedValueOnce(new RequestError(409, "transcript_changed_refetch_without_after"));
    await service.step(job.id, userId, signal);
    expect(store.saveSnapshot).not.toHaveBeenCalled(); expect(store.releaseMeeting).toHaveBeenCalled();
    expect(store.finish).toHaveBeenCalledWith(expect.anything(), job, 30, true);
  });
  it("stops on revoked permission and rejects fabricated evidence", async () => {
    const { service, store, sync, generate, job } = fixture(); sync.getWorkspace.mockResolvedValue(null);
    await service.step(job.id, userId, signal); expect(store.claimMeeting).not.toHaveBeenCalled();
    expect(store.finish).toHaveBeenCalledWith(expect.anything(), job);
    sync.getWorkspace.mockResolvedValue({ encryption: "none" });
    generate.mockResolvedValue({ ...emptyLiveNotes, topics: [{ text: "Invented", segmentIds: [uuidV7()] }] });
    await service.step(job.id, userId, signal);
    expect(store.saveSnapshot).not.toHaveBeenCalled();
    expect(store.finish).toHaveBeenLastCalledWith(expect.anything(), job, 30, true);
  });
});
