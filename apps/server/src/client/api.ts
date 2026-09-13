import createClient from "openapi-fetch";
import type { paths, components } from "./generated-api";
export type SyncedVaultInfo = components["schemas"]["Vault"];
export type OrganizationInfo = components["schemas"]["Organization"];
export type SyncedMeetingInfo = components["schemas"]["Meeting"];
export type SyncedMeetingPage = { items: SyncedMeetingInfo[]; nextCursor: string | null };
export type SyncedProjectInfo = components["schemas"]["Project"];

export function uiText(english: string, japanese: string): string {
  return globalThis.navigator?.language.startsWith("ja") ? japanese : english;
}

export const canWriteVault = (role: unknown) => role === "admin" || role === "editor";
export const vaultRoleLabel = (role: SyncedVaultInfo["role"]) => role === "admin" ? uiText("Admin", "管理者")
  : role === "editor" ? uiText("Editor", "編集者") : uiText("Viewer", "閲覧者");

export function syncMessage(code: string, language = globalThis.navigator?.language ?? "en"): string | undefined {
  const messages: Record<string, [string, string]> = {
    vault_delete_confirmation_stale: ["The Vault changed. Close this dialog and confirm deletion again.", "保管庫が変更されました。この画面を閉じ、削除内容を再確認してください。"],
    last_vault_admin: ["Keep at least one Vault Admin.", "保管庫の管理者を最低1人残してください。"],
    last_organization_owner: ["Keep at least one organization owner.", "組織の所有者を最低1人残してください。"],
    last_team_member: ["Keep at least one team member.", "チームのメンバーを最低1人残してください。"],
    personal_vault_immutable: ["The Personal Vault cannot be shared or deleted.", "Personal保管庫は共有・削除できません。"],
    organization_delete_forbidden: ["This organization cannot be deleted.", "この組織は削除できません。"],
    transfer_audience_changed: ["Readers changed. Close this dialog and review the transfer again.", "閲覧者が変更されました。この画面を閉じ、移管内容を再確認してください。"],
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

export const serverClient = createClient<paths>({
  baseUrl: globalThis.location?.origin ?? "http://localhost",
  headers: { "X-Dahlia-Vault-Transfers": "1" },
  fetch: (request) => globalThis.fetch(request),
});

export async function unwrap<T>(pending: Promise<{ data?: T; error?: unknown; response: Response }>, notifyMutation = false): Promise<T> {
  const { data, error, response } = await pending;
  if (!response.ok) {
    if (response.status === 401 && typeof window !== "undefined") window.dispatchEvent(new Event("dahlia:unauthorized"));
    const problem = error as components["schemas"]["Problem"] | undefined;
    throw new RequestError((problem?.code && syncMessage(problem.code)) || problem?.detail || problem?.code || `Request failed (${response.status})`, response.status);
  }
  if (notifyMutation && typeof window !== "undefined") window.dispatchEvent(new Event(clientMutationEvent));
  return data as T;
}
