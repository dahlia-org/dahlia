import type { Identity } from "./auth/identity";
import type { ApplicationStore } from "./auth/store";
import type { AppConfig } from "./config";
import { uuidV7 } from "./id";
import { summaryDocument } from "./summary/model";
import type { MeetingSyncService } from "./sync/service";

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
  if ((await sync.listVaults(identity, identity.userId)).length) return;
  const now = new Date().toISOString();
  const vaultId = uuidV7();
  const projectId = uuidV7();
  const operations = [{ id: uuidV7(), entity: "vault", action: "create", entityId: vaultId, baseRevision: null,
    data: { name: "サンプル保管庫", createdAt: now } },
  { id: uuidV7(), entity: "project", action: "create", entityId: projectId, baseRevision: null,
    data: { name: "新サービス開発", description: "ローカル動作確認用のサンプルプロジェクト", parentProjectId: null, projectType: null, createdAt: now } }];
  const meetings = ["週次進捗ミーティング", "デザインレビュー", "顧客ヒアリング"];
  await sync.commitTransaction(identity, {
    schemaVersion: 2, id: uuidV7(), vaultId, createdAt: now,
    operations: [...operations, ...meetings.flatMap((name, index) => {
      const meetingId = uuidV7();
      const createdAt = new Date(Date.now() - index * 86_400_000).toISOString();
      const document = summaryDocument({ title: name, description: "サンプルデータ：開発の進捗と次のアクションを確認しました。",
        tags: ["sample"], action_items: [{ title: "次回までに画面案を更新する", assignee: "担当者" }],
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
}
