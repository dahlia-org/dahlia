import type { Identity } from "../auth/identity";

export interface SyncManifest {
  vaultId: string;
  meetingId: string;
  projectId: string | null;
  name: string;
  description: string;
  status: string;
  duration: number | null;
  recordingStartedAt: Date | null;
  createdAt: Date;
  updatedAt: Date;
  summaryTitle: string | null;
  summaryDocument: string | null;
  summaryCreatedAt: Date | null;
  activeTranscriptGeneration: string | null;
  searchText: string;
  embeddingText: string | null;
  embeddingContentHash: string | null;
  screenshots: Array<{
    screenshotId: string;
    capturedAt: Date;
    ocrText: string | null;
    caption: string | null;
    searchText: string;
    embeddingText: string | null;
    embeddingContentHash: string | null;
  }>;
}

export interface SyncTranscriptSegment {
  segmentId: string;
  startTime: Date;
  endTime: Date | null;
  text: string;
  isConfirmed: boolean;
  audioSource: string | null;
  speakerLabel: string | null;
}

export interface SyncVaultManifest {
  vaultId: string;
  name: string;
  createdAt: Date;
  projects: SyncProjectRecord[];
}

export interface SyncVaultRecord {
  vaultId: string;
  name: string;
  createdAt: Date;
  updatedAt: Date;
  role: VaultRole;
}

export interface SyncProjectRecord {
  projectId: string;
  vaultId: string;
  parentProjectId: string | null;
  name: string;
  description: string;
  projectType: "customer" | "internal" | "personal" | "undefined" | null;
  revision: number;
  createdAt: Date;
}

export interface SyncProjectView extends SyncProjectRecord {
  path: string;
  rootProjectId: string;
  effectiveType: "customer" | "internal" | "personal" | "undefined";
  typeOwnerProjectId: string;
  directMeetingCount: number;
  subtreeMeetingCount: number;
}

export type VaultRole = "owner" | "member";
export type VaultPrincipalType = "user" | "organization" | "team";

export interface VaultPermissionRecord {
  vaultId: string;
  principalType: VaultPrincipalType;
  principalId: string;
  role: VaultRole;
  createdAt: Date;
}

export interface SyncMeetingRecord {
  meetingId: string;
  vaultId: string;
  projectId: string | null;
  name: string;
  description: string;
  status: string;
  duration: number | null;
  recordingStartedAt: Date | null;
  createdAt: Date;
  updatedAt: Date;
  summaryTitle: string | null;
  summaryDocument: string | null;
  summaryCreatedAt: Date | null;
  activeTranscriptGeneration: string | null;
}

export interface SyncScreenshotRecord {
  screenshotId: string;
  vaultId: string;
  meetingId: string;
  capturedAt: Date;
  contentType: string;
  storageKey: string;
  contentLength: number;
  ocrText: string | null;
  caption: string | null;
}

export interface SyncSearchQuery {
  text: string;
  tokens: string[];
  ftsCandidateIds?: string[];
  embedding?: {
    model: string;
    dimensions: number;
    vector: number[];
  };
}

export interface IdentitySyncStore {
  commitVaultManifest(manifest: SyncVaultManifest): Promise<boolean>;
  ensureUploadTarget(vaultId: string, meetingId: string): Promise<boolean>;
  commitManifest(manifest: SyncManifest): Promise<{
    committed: boolean;
    missingScreenshotContent: boolean;
    obsoleteScreenshots: SyncScreenshotRecord[];
  }>;
  putTranscriptChunk(
    vaultId: string,
    meetingId: string,
    generation: string,
    segments: SyncTranscriptSegment[],
  ): Promise<boolean>;
  getScreenshot(
    vaultId: string,
    meetingId: string,
    screenshotId: string,
    activeOnly?: boolean,
  ): Promise<SyncScreenshotRecord | null>;
  createScreenshot(input: SyncScreenshotRecord): Promise<boolean>;
  deleteScreenshot(vaultId: string, screenshotId: string, storageKey: string): Promise<boolean>;
  listVaults(): Promise<SyncVaultRecord[]>;
  getVault(vaultId: string): Promise<SyncVaultRecord | null>;
  listProjects(vaultId: string): Promise<SyncProjectView[]>;
  getProject(vaultId: string, projectId: string): Promise<SyncProjectView | null>;
  listMeetings(vaultId: string, query: SyncSearchQuery | undefined, limit: number, projectId?: string): Promise<SyncMeetingRecord[]>;
  getMeeting(vaultId: string, meetingId: string): Promise<SyncMeetingRecord | null>;
  listTranscript(vaultId: string, meetingId: string, limit: number): Promise<SyncTranscriptSegment[]>;
  listScreenshots(vaultId: string, meetingId: string, query: SyncSearchQuery | undefined, limit: number): Promise<SyncScreenshotRecord[]>;
  listPermissions(vaultId: string): Promise<VaultPermissionRecord[] | null>;
  putMemberPermission(vaultId: string, principalType: VaultPrincipalType, principalId: string): Promise<boolean>;
  deleteMemberPermission(vaultId: string, principalType: VaultPrincipalType, principalId: string): Promise<boolean>;
  beginMeetingDeletion(vaultId: string, meetingId: string, limit: number): Promise<SyncScreenshotRecord[] | null>;
  finishMeetingDeletion(vaultId: string, meetingId: string): Promise<boolean>;
  beginVaultDeletion(vaultId: string, limit: number): Promise<SyncScreenshotRecord[] | null>;
  finishVaultDeletion(vaultId: string): Promise<boolean>;
}

export interface MeetingSyncStore {
  isAvailable(): Promise<boolean>;
  withIdentity<T>(identity: Identity, action: (store: IdentitySyncStore) => Promise<T>): Promise<T>;
}
