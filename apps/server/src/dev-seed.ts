import { encodeSyncCursor } from "./sync/store";
import type { Identity } from "./auth/identity";
import type { ApplicationStore } from "./auth/store";
import type { AppConfig } from "./config";
import { uuidV7 } from "./id";
import { summaryDocument } from "./summary/model";
import { sha256 } from "./storage/sha256";
import { RequestError } from "./storage/upload";
import type { MeetingSyncService } from "./sync/service";
import type { SyncTransaction } from "./sync/types";

const sampleDescription = "サンプルデータ：開発の進捗と次のアクションを確認しました。";
const sampleTag = "dahlia_dev_seed";
const sampleTranscripts = new Map([
  ["週次進捗ミーティング", ["今週は検索画面と会議一覧の改善を進めました。", "検索結果の表示速度を優先して調整します。", "次回までに画面案を更新し、来週のレビューで確認します。"]],
  ["デザインレビュー", ["新しいミーティング詳細画面のデザインを確認します。", "主要な操作はタイトル付近にまとめる方針で合意しました。", "モーダルの余白とモバイル表示を次回までに調整します。"]],
  ["顧客ヒアリング", ["会議後に要点とアクションをすぐ確認したいという要望がありました。", "文字起こしから要約を再生成できることを説明しました。", "次回は実際の利用フローで操作性を確認します。"]],
]);
type SeedMeeting = { meetingId: string; name: string; createdAt: string; transcriptRevision: number; isRecording?: boolean };

async function isSampleMeeting(identity: Identity, sync: MeetingSyncService, workspaceId: string,
  meeting: { meetingId: string; name: string; description: string; hasSummary: boolean }): Promise<boolean> {
  if (!sampleTranscripts.has(meeting.name) || meeting.description !== sampleDescription || !meeting.hasSummary) return false;
  const summaryDocument = (await sync.latestSummary(identity, workspaceId, meeting.meetingId)).record?.document;
  if (typeof summaryDocument !== "string") return false;
  try {
    const document = JSON.parse(summaryDocument) as { title?: unknown; description?: unknown; tags?: unknown };
    return document.title === meeting.name && document.description === sampleDescription
      && Array.isArray(document.tags) && document.tags.length === 1
      && (document.tags[0] === sampleTag || document.tags[0] === "sample");
  } catch { return false; }
}

/** Only the local Node development command installs this identity hook. */
export function installDevelopmentSeed(config: AppConfig, store: ApplicationStore, sync: MeetingSyncService): void {
  if (config.databaseType !== "sqlite" || !["localhost", "127.0.0.1", "[::1]"].includes(new URL(config.baseUrl).hostname)) return;
  const projectUser = store.ensureIdentityUser.bind(store);
  const seedTasks = new Map<string, Promise<void>>();
  store.ensureIdentityUser = async (identity) => {
    if (!await projectUser(identity)) return false;
    if (identity.impersonated) return true;
    let pending = seedTasks.get(identity.userId);
    if (!pending) {
      pending = seedEmptyAccount(identity, sync);
      seedTasks.set(identity.userId, pending);
      pending.catch(() => seedTasks.delete(identity.userId));
    }
    await pending;
    return true;
  };
}

async function seedEmptyAccount(identity: Identity, sync: MeetingSyncService): Promise<void> {
  const workspace = (await sync.listWorkspaces(identity)).find((workspace) => workspace.personalUserId === identity.userId);
  if (!workspace) return;
  const now = new Date().toISOString();
  const workspaceId = workspace.workspaceId;
  let meetings: SeedMeeting[];
  if ((await sync.listSnapshot(identity, workspaceId)).startCursor === encodeSyncCursor(0)) {
    const projectId = uuidV7();
    meetings = [...sampleTranscripts.keys()].map((name, index) => {
      const meetingId = uuidV7();
      const createdAt = new Date(Date.now() - index * 86_400_000).toISOString();
      return { meetingId, name, createdAt, transcriptRevision: 0 };
    });
    await sync.commitTransaction(identity, {
      schemaVersion: 3, id: uuidV7(), workspaceId, createdAt: now,
      operations: [{ id: uuidV7(), entity: "project", action: "create", entityId: projectId, baseRevision: null,
        data: { name: "新サービス開発", description: "ローカル動作確認用のサンプルプロジェクト", parentProjectId: null, projectType: null, createdAt: now } },
      ...meetings.flatMap(({ meetingId, name, createdAt }, index) => {
        const document = summaryDocument({ title: name, description: sampleDescription,
          tags: [sampleTag], action_items: [{ title: "次回までに画面案を更新する", assignee: "担当者" }],
          sections: [{ heading: "決定事項", blocks: [{ type: "paragraph", level: 3,
            content: { text: "検索と会議一覧の使いやすさを優先し、来週のレビューで改善案を確認します。", transcript_ref: null },
            items: [], language: "", image_id: "" }] }] }, new Set());
        return [{ id: uuidV7(), entity: "meeting", action: "create", entityId: meetingId, baseRevision: null,
          data: { name, description: document.description, status: "READY", projectId: index === 2 ? null : projectId,
            duration: (index + 1) * 900, recordingStartedAt: createdAt, createdAt, updatedAt: createdAt } },
        { id: uuidV7(), entity: "summary", action: "upsert", entityId: meetingId, baseRevision: 0,
          data: { title: name, document: JSON.stringify(document), createdAt } }];
      })],
    });
  } else {
    meetings = [];
    let cursor: string | undefined;
    do {
      const page = await sync.listMeetings(identity, workspaceId, undefined, undefined, undefined, cursor);
      const samples = await Promise.all(page.items.map(async (meeting) => await isSampleMeeting(identity, sync, workspaceId, meeting) ? meeting : null));
      meetings.push(...samples.filter((meeting) => meeting !== null).map((meeting) => ({ meetingId: meeting.meetingId, name: meeting.name,
        createdAt: meeting.createdAt.toISOString(), transcriptRevision: meeting.transcriptRevision ?? 0, isRecording: meeting.isRecording })));
      cursor = page.nextCursor;
    } while (cursor);
    if (meetings.length !== sampleTranscripts.size || new Set(meetings.map(({ name }) => name)).size !== sampleTranscripts.size) meetings = [];
  }
  await seedMissingTranscripts(identity, sync, workspaceId, meetings, now);
}

async function seedMissingTranscripts(identity: Identity, sync: MeetingSyncService, workspaceId: string,
  meetings: SeedMeeting[], now: string) {
  for (const meeting of meetings) {
    if (meeting.transcriptRevision !== 0 || meeting.isRecording || await hasRecordingsOrUploads(identity, sync, meeting.meetingId)) continue;
    if ((await sync.transcriptVersions(identity, workspaceId, meeting.meetingId)).items.length) continue;
    const texts = sampleTranscripts.get(meeting.name);
    if (!texts) continue;
    const patchId = uuidV7();
    const startedAt = new Date(meeting.createdAt);
    const segments = texts.map((text, index) => ({ segmentId: uuidV7(),
      startedAt: new Date(startedAt.getTime() + index * 60_000).toISOString(),
      endedAt: new Date(startedAt.getTime() + index * 60_000 + 45_000).toISOString(),
      text, createdAt: now, audioSource: index % 2 ? "system" as const : "mic" as const,
      speakerLabel: index % 2 ? "佐藤" : "田中" }));
    const chunk = { segments, deletions: [] };
    const hash = await sha256(JSON.stringify(chunk));
    await sync.putTranscriptChunk(identity, meeting.meetingId, patchId, 0, hash, chunk);
    const operation: SyncTransaction["operations"][number] = { id: patchId, entity: "transcript", action: "patch",
      entityId: meeting.meetingId, baseRevision: meeting.transcriptRevision,
      data: { transcript: { id: uuidV7(), startedAt: meeting.createdAt, endedAt: segments.at(-1)!.endedAt, metadata: null },
        mode: "replace", patchId, segmentCount: segments.length, deletionCount: 0,
        chunks: [{ index: 0, sha256: hash, segmentCount: segments.length, deletionCount: 0 }] } };
    await sync.commitTransaction(identity, { schemaVersion: 3, id: uuidV7(), workspaceId, createdAt: now, operations: [operation] });
  }
}

async function hasRecordingsOrUploads(identity: Identity, sync: MeetingSyncService, meetingId: string): Promise<boolean> {
  try { return (await sync.listRecordings(identity, meetingId, undefined, true)).items.length > 0; }
  catch (error) {
    if (error instanceof RequestError && error.status === 409) return true;
    throw error;
  }
}
