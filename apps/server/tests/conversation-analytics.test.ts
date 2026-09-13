import { describe, expect, it } from "vitest";
import type { Identity } from "../src/auth/identity";
import {
  ConversationAnalyticsService,
  normalizedCharacterCount,
} from "../src/conversation-analytics";
import type { RecordingRecord, RecordingSource } from "../src/recordings/model";
import type {
  IdentitySyncStore,
  MeetingSyncStore,
  TranscriptAnalyticsSegment,
} from "../src/sync/types";
import type { TranscriptMetadata, TranscriptVersion } from "../src/sync/transcript";
import type { AppConfig } from "../src/config";
import { createContractApp } from "./api-test-client";
import { testStore } from "./test-store";
import { testUserID } from "./public-test-client";
import { createWorkerHandler } from "../src/worker";

const identity: Identity = { userId: "owner",  source: "header" };
const workspaceId = "019d3f46-7e0d-7d21-98d9-f1456c0bfb58";
const meetingId = "019d3f46-8b72-77f1-b232-93726eec3e9e";
const base = new Date("2026-09-11T00:00:00.000Z");
const at = (seconds: number) => new Date(base.getTime() + seconds * 1000);

function recording(number: number, start: number, end: number, enabled: RecordingSource[] = ["mic", "system"]): RecordingRecord {
  const audio = Object.fromEntries(enabled.map((source) => [source, {
    generation: `${number}-${source}`,
    createdAt: at(start).toISOString(),
    uploadedAt: at(end).toISOString(),
    active: true,
    content_type: "audio/mp4" as const,
    size: 1,
    checksum: `SHA-256:${"a".repeat(64)}`,
  }]));
  return { sessionId: `019d3f46-8c00-7000-8000-${String(number).padStart(12, "0")}`, workspaceId, meetingId, number, startedAt: at(start), endedAt: at(end), audio,
    revision: 1, createdAt: at(start), updatedAt: at(end) };
}

function transcript(version: number, metadata: TranscriptMetadata | null = null): TranscriptVersion {
  return { id: `019d3f46-8d00-7000-8000-00000000000${version}`, meetingId, version, syncRevision: version,
    status: "ended", latestSegmentCreatedAt: null, startedAt: base, endedAt: at(60), createdAt: base, metadata };
}

function desktopMetadata(...sessionIds: string[]): TranscriptMetadata {
  return { provider: "apple", request: { model: "apple-speech" }, runs: sessionIds.map((recordingSessionId) => ({
    generatedBy: "desktop", inputTypes: ["audio"], recordingSessionId,
  })) };
}

function serverMetadata(...audioInputs: NonNullable<TranscriptMetadata["runs"][number]["audioInputs"]>): TranscriptMetadata {
  return { provider: "gemini", request: { model: "gemini" }, runs: [{ generatedBy: "server", inputTypes: ["audio"], audioInputs }] };
}

function service(options: {
  role?: "admin" | "editor" | "viewer";
  recordings?: RecordingRecord[];
  segments?: Record<number, TranscriptAnalyticsSegment[]>;
  versions?: number[];
  activeVersions?: number[];
  metadata?: Record<number, TranscriptMetadata | null>;
} = {}) {
  const versions = options.versions ?? [1];
  const recordings = options.recordings ?? [];
  const scoped = {
    getWorkspace: async () => ({ role: options.role ?? "admin" }),
    getMeeting: async () => ({ meetingId }),
    getTranscript: async (_workspaceId: string, _meetingId: string, version?: number) => {
      const selectedVersion = version ?? Math.max(...versions);
      if (!versions.includes(selectedVersion)) return null;
      const metadata = options.metadata && selectedVersion in options.metadata
        ? options.metadata[selectedVersion] ?? null
        : recordings.length ? desktopMetadata(...recordings.map(({ sessionId }) => sessionId)) : null;
      const value = transcript(selectedVersion, metadata);
      return options.activeVersions?.includes(selectedVersion) ? { ...value, status: "active" as const, endedAt: null } : value;
    },
    listRecordings: async (_meetingId: string, after: number, limit: number) =>
      recordings.filter((value) => value.number > after).slice(0, limit),
    listTranscriptAnalytics: async (_workspaceId: string, _meetingId: string, version: number) =>
      options.segments?.[version] ?? [],
  } as unknown as IdentitySyncStore;
  const store = { withIdentity: async <T>(_identity: Identity, action: (value: IdentitySyncStore) => Promise<T>) => action(scoped) } as MeetingSyncStore;
  return new ConversationAnalyticsService(store);
}

describe("conversation analytics", () => {
  it.each([
    ["", 0],
    [" \t\n　", 0],
    ["A 👨‍👩‍👧‍👦 e\u0301", 3],
    ["こんにちは 世界", 7],
  ])("counts Unicode graphemes without whitespace", (text, expected) => {
    expect(normalizedCharacterCount(text)).toBe(expected);
  });

  it("joins recordings by number and calculates overlap, invalid timing, pace, and versions", async () => {
    const analytics = service({
      recordings: [recording(2, 20, 30), recording(1, 0, 10)],
      versions: [1, 2],
      segments: {
        1: [
          { segmentId: "m1", startedAt: at(1), endedAt: at(5), audioSource: "mic", normalizedCharacterCount: 8 },
          { segmentId: "s1", startedAt: at(3), endedAt: at(7), audioSource: "system", normalizedCharacterCount: 4 },
          { segmentId: "m2", startedAt: at(22), endedAt: at(26), audioSource: "mic", normalizedCharacterCount: 12 },
          { segmentId: "bad", startedAt: at(8), endedAt: at(7), audioSource: "mic", normalizedCharacterCount: 2 },
        ],
        2: [{ segmentId: "v2", startedAt: at(2), endedAt: at(4), audioSource: "system", normalizedCharacterCount: 3 }],
      },
    });

    const first = await analytics.get(identity, workspaceId, meetingId, 1);
    expect(first).toMatchObject({ status: "ready", transcriptVersion: 1, recordingDuration: 20,
      unionSpeechDuration: 10, overlapDuration: 2, conversationOccupancyRatio: 0.5, overlapRatio: 0.2 });
    if (first.status !== "ready") throw new Error("expected ready analytics");
    expect(first.sources).toEqual([
      expect.objectContaining({ source: "mic", speechDuration: 8, normalizedCharacterCount: 22,
        segmentCount: 3, unmeasurableSegmentCount: 1, speechShare: 2 / 3 }),
      expect.objectContaining({ source: "system", speechDuration: 4, normalizedCharacterCount: 4,
        segmentCount: 1, unmeasurableSegmentCount: 0, speechShare: 1 / 3 }),
    ]);
    expect(first.longestMonologue).toMatchObject({ source: "mic", start: 1, end: 5 });
    expect(first.overlapIntervals).toEqual([{ start: 3, end: 5 }]);
    expect((await analytics.get(identity, workspaceId, meetingId, 2))).toMatchObject({
      status: "ready", transcriptVersion: 2, unionSpeechDuration: 2,
    });
  });

  it("condenses long timelines and reports missing audio without exposing member data", async () => {
    const longSegments = Array.from({ length: 600 }, (_, index) => ({
      segmentId: String(index), startedAt: at(index * 3), endedAt: at(index * 3 + 1),
      audioSource: "mic", normalizedCharacterCount: 1,
    }));
    const ready = await service({ recordings: [recording(1, 0, 3600, ["mic"])], segments: { 1: longSegments } })
      .get(identity, workspaceId, meetingId, 1);
    expect(ready).toMatchObject({ status: "ready", isTimelineCondensed: true });
    if (ready.status !== "ready") throw new Error("expected ready analytics");
    expect(ready.timelineIntervals.length).toBeLessThanOrEqual(512);
    expect(ready.paceSamples.length).toBeLessThanOrEqual(60);

    const missing = await service({ recordings: [recording(1, 0, 10, ["system"])], segments: { 1: [
      { segmentId: "mic", startedAt: at(1), endedAt: at(2), audioSource: "mic", normalizedCharacterCount: 1 },
    ] } }).get(identity, workspaceId, meetingId, 1);
    expect(missing).toEqual({ status: "unavailable", transcriptId: transcript(1).id,
      transcriptVersion: 1, reason: "recording_audio_missing" });
    await expect(service({ activeVersions: [1] }).get(identity, workspaceId, meetingId, 1))
      .rejects.toMatchObject({ status: 409, code: "transcript_version_not_finalized" });
    await expect(service({ recordings: [recording(1, 0, 10)], versions: [1, 2], activeVersions: [1] })
      .get(identity, workspaceId, meetingId, 1)).resolves.toMatchObject({ status: "ready", transcriptVersion: 1 });
    await expect(service({ role: "viewer" }).get(identity, workspaceId, meetingId, 1)).rejects.toMatchObject({ status: 404 });
    await expect(service({ versions: [] }).get(identity, workspaceId, meetingId, 1)).rejects.toMatchObject({ status: 404 });
  });

  it("binds each transcript version to its metadata recording inputs", async () => {
    const recordings = [recording(1, 0, 10), recording(2, 20, 30), recording(3, 40, 140)];
    const checksum = recordings[1]!.audio.mic!.checksum!;
    const analytics = service({
      recordings,
      versions: [1, 2, 3, 4, 5],
      metadata: {
        1: desktopMetadata(recordings[0]!.sessionId.toUpperCase()),
        2: serverMetadata({ recordingNumber: 2, source: "mic", checksum }),
        3: serverMetadata({ recordingNumber: 2, source: "mic", checksum }),
        4: serverMetadata({ recordingNumber: 2, source: "mic", checksum: `SHA-256:${"b".repeat(64)}` }),
        5: null,
      },
      segments: {
        1: [{ segmentId: "desktop", startedAt: at(1), endedAt: at(3), audioSource: "mic", normalizedCharacterCount: 2 }],
        2: [{ segmentId: "server", startedAt: at(22), endedAt: at(24), audioSource: "mic", normalizedCharacterCount: 2 }],
        3: [{ segmentId: "unreferenced-source", startedAt: at(22), endedAt: at(24), audioSource: "system", normalizedCharacterCount: 2 }],
      },
    });

    await expect(analytics.get(identity, workspaceId, meetingId, 1)).resolves.toMatchObject({ status: "ready", recordingDuration: 10 });
    await expect(analytics.get(identity, workspaceId, meetingId, 2)).resolves.toMatchObject({ status: "ready", recordingDuration: 10 });
    for (const version of [3, 4, 5]) {
      await expect(analytics.get(identity, workspaceId, meetingId, version)).resolves.toMatchObject({
        status: "unavailable", transcriptVersion: version, reason: "recording_audio_missing",
      });
    }
  });

  it("waits for every reserved Desktop recording track to be committed", async () => {
    const partiallyCommitted = recording(1, 0, 10);
    partiallyCommitted.audio.system = { ...partiallyCommitted.audio.system!, active: false };
    const segments = { 1: [
      { segmentId: "mic", startedAt: at(1), endedAt: at(3), audioSource: "mic", normalizedCharacterCount: 2 },
    ] };

    await expect(service({ recordings: [partiallyCommitted], segments }).get(identity, workspaceId, meetingId, 1))
      .resolves.toMatchObject({ status: "unavailable", reason: "recording_audio_missing" });
    await expect(service({ recordings: [recording(1, 0, 10)], segments }).get(identity, workspaceId, meetingId, 1))
      .resolves.toMatchObject({ status: "ready" });
  });

  it.each(["node", "worker"])("exposes capability and writer-only unavailable responses through %s", async (runtime) => {
    const ownerId = testUserID("analytics-owner@example.com");
    const baseStore = testStore();
    const sync = {
      ...baseStore.sync,
      isAvailable: () => Promise.resolve(true),
      withIdentity: async <T>(requestIdentity: Identity, action: (value: IdentitySyncStore) => Promise<T>) => action({
        resolveEntityWorkspace: async () => workspaceId,
        getWorkspace: async () => ({ role: requestIdentity.userId === ownerId ? "admin" : "viewer" }),
        getMeeting: async () => ({ meetingId }),
        getTranscript: async (_workspaceId: string, _meetingId: string, version: number) => version === 1 ? transcript(1) : null,
        listRecordings: async () => [],
        listTranscriptAnalytics: async () => [],
      } as unknown as IdentitySyncStore),
    } satisfies MeetingSyncStore;
    const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite",
      databaseUrl: "file::memory:", baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576 };
    const app = createContractApp({ config, authStore: testStore({ sync }) });
    const worker = createWorkerHandler(async () => app);
    const fetch = worker.fetch!.bind(worker) as unknown as
      (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    const send = (path: string, userId = ownerId) => {
      const request = new Request(`http://localhost:5173${path}`, { headers: {
        "x-forwarded-user": userId, "x-forwarded-email": userId === ownerId ? "analytics-owner@example.com" : "analytics-member@example.com",
      } });
      return runtime === "node" ? app.request(request) : fetch(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };

    expect(await (await send("/api/v1/capabilities")).json()).toHaveProperty("conversationAnalytics", { version: 1 });
    const path = `/api/v1/meetings/${meetingId}/transcripts/1/conversation-analytics`;
    expect(await (await send(path)).json()).toEqual({ status: "unavailable", transcriptId: transcript(1).id,
      transcriptVersion: 1, reason: "recording_audio_missing" });
    expect((await send(path, testUserID("analytics-member"))).status).toBe(404);
    expect((await send(path.replace("/1/", "/2/"))).status).toBe(404);
    expect((await send(path.replace("/1/", "/999999999999999999999/"))).status).toBe(400);
  });
});
