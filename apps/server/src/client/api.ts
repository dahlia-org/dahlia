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

export class RequestError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
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
      detail?.message || error || `Request failed (${response.status})`,
      response.status,
    );
  }
  return (response.status === 204 ? undefined : await response.json()) as T;
}
