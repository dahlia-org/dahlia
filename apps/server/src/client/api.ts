import type { Appearance } from "../appearance-model";
export interface SyncedVaultInfo {
  hasResources?: boolean;
  vaultId: string;
  name: string;
  appearance?: Appearance | null;
  role: "owner" | "member";
  createdAt: string;
  updatedAt: string;
  revision: number;
}

export interface OrganizationInfo {
  id: string;
  name: string;
  slug: string;
}

export interface SyncedMeetingInfo {
  meetingId: string;
  vaultId: string;
  projectId?: string;
  name: string;
  description: string;
  status: string;
  duration?: number;
  recordingStartedAt?: string;
  isRecording?: boolean;
  createdAt: string;
  updatedAt: string;
  revision: number;
  summaryRevision: number;
  transcriptRevision: number;
}

export interface SyncedMeetingPage {
  items: SyncedMeetingInfo[];
  nextCursor?: string;
}

export interface SyncedProjectInfo {
  projectId: string;
  vaultId: string;
  parentProjectId?: string;
  name: string;
  appearance?: Appearance | null;
  description: string;
  projectType?: "customer" | "internal" | "personal" | "undefined";
  effectiveType: "customer" | "internal" | "personal" | "undefined";
  revision: number;
  path: string;
  directMeetingCount: number;
  subtreeMeetingCount: number;
}

export function uiText(english: string, japanese: string): string {
  return globalThis.navigator?.language.startsWith("ja") ? japanese : english;
}

export function syncMessage(code: string, language = globalThis.navigator?.language ?? "en"): string | undefined {
  const messages: Record<string, [string, string]> = {
    transfer_unsynced_data: ["Uploads or uncommitted data remain. Complete sync and try again.", "アップロード中または未確定のデータがあります。同期完了後に再試行してください。"],
    transfer_processing: ["Recording or processing is in progress. Try again when it finishes.", "録音または処理が進行中です。完了後に再試行してください。"],
    transfer_name_conflict: ["The destination already has a root Project with the same name.", "移管先に同名のルートプロジェクトがあります。名前を変更してから再試行してください。"],
    transfer_access_required: ["Sync is paused until access to the destination Vault is restored. Local data is retained.", "移管先の権限が復旧するまで同期を停止しています。ローカルデータは保持されています。"],
    vault_not_empty: ["This Vault contains resources. Transfer or delete them before deleting the Vault.", "リソースが残っているため削除できません。先に移管するか、リソースを削除してください。"],
    sync_recovering: ["Checking the saved result and retrieving latest data…", "保存結果を確認し、最新のデータを取得中…"],
    revision_conflict: ["This data has changed. Reload the latest version before choosing your changes.", "データが変更されています。最新の状態を読み込み、変更内容を確認してください。"],
    sync_upgrade_required: ["Update Dahlia Server and reload this page to resume sync.", "Dahlia Serverを更新し、このページを再読み込みして同期を再開してください。"],
    sync_cursor_expired: ["Reload the latest data to resume sync.", "最新のデータを再読み込みして同期を再開してください。"],
  };
  return messages[code]?.[language.startsWith("ja") ? 1 : 0];
}

export class RequestError extends Error {
  constructor(message: string, readonly status?: number, options?: ErrorOptions) {
    super(message, options);
  }
}

export const clientMutationEvent = "dahlia:mutation";

export async function json<T>(url: string, init?: RequestInit, { notifyMutation = true }: { notifyMutation?: boolean } = {}): Promise<T> {
  const response = await fetch(url, {
    ...init,
    headers: { "X-Dahlia-Vault-Transfers": "1", ...(init?.body ? { "content-type": "application/json" } : {}), ...init?.headers },
  });
  if (!response.ok) {
    if (response.status === 401 && typeof window !== "undefined") {
      window.dispatchEvent(new Event("dahlia:unauthorized"));
    }
    const detail = (await response.json().catch(() => null)) as {
      message?: string;
      error?: string | { message?: string };
    } | null;
    const error = typeof detail?.error === "string" ? detail.error : detail?.error?.message;
    throw new RequestError(
      (error && syncMessage(error)) || detail?.message || error || `Request failed (${response.status})`,
      response.status,
    );
  }
  const value = response.status === 204 ? undefined : await response.json();
  if (notifyMutation && typeof window !== "undefined" && !["GET", "HEAD", "OPTIONS"].includes(init?.method?.toUpperCase() ?? "GET")) {
    window.dispatchEvent(new Event(clientMutationEvent));
  }
  return value as T;
}
