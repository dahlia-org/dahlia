export interface SyncedVaultInfo {
  vaultId: string;
  name: string;
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
  createdAt: string;
  updatedAt: string;
  summaryTitle?: string;
  summaryDocument?: string;
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
  description: string;
  projectType?: "customer" | "internal" | "personal" | "undefined";
  effectiveType: "customer" | "internal" | "personal" | "undefined";
  revision: number;
  path: string;
  directMeetingCount: number;
  subtreeMeetingCount: number;
}

export function syncMessage(code: string, language = globalThis.navigator?.language ?? "en"): string | undefined {
  const messages: Record<string, [string, string]> = {
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

export async function json<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, {
    ...init,
    headers: init?.body ? { "content-type": "application/json", ...init.headers } : init?.headers,
  });
  if (!response.ok) {
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
  return (response.status === 204 ? undefined : await response.json()) as T;
}
