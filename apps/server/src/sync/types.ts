import type { Identity } from "../auth/identity";

export interface SyncTranscriptSegment {
  segmentId: string;
  startTime: Date;
  endTime: Date | null;
  text: string;
  isConfirmed: boolean;
  audioSource: string | null;
  speakerLabel: string | null;
}

export interface SyncTranscriptCursor {
  startTime: Date;
  segmentId: string;
}

export interface SyncVaultRecord {
  vaultId: string;
  name: string;
  revision?: number;
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
export type SyncEntity = "vault" | "project" | "meeting" | "summary" | "transcript" | "screenshot";
export type SyncAction = "create" | "update" | "delete" | "upsert" | "patch" | "reset";

export interface SyncTransactionOperation {
  id: string;
  entity: SyncEntity;
  action: SyncAction;
  entityId: string;
  baseRevision: number | null;
  data: Record<string, unknown> | null;
}

export interface SyncTransaction {
  schemaVersion: 1;
  id: string;
  vaultId: string;
  createdAt: Date;
  requestHash: string;
  operations: SyncTransactionOperation[];
}

export interface SyncCanonicalRecord {
  entity: SyncEntity;
  id: string;
  revision: number | null;
  record: Record<string, unknown> | null;
}

export interface SyncTransactionResponse {
  id: string;
  status: "committed";
  cursor: string;
  receipt?: "full" | "compact";
  records: (Pick<SyncCanonicalRecord, "entity" | "id" | "revision"> & { record?: Record<string, unknown> | null })[];
}

export interface SyncSnapshotPosition {
  entity: SyncEntity;
  id: string;
}

export interface SyncRetentionResult {
  changesDeleted: number;
  receiptsCompacted: number;
}

export interface SyncHistoryTarget {
  ownerUserId: string;
  vaultId: string;
}

export interface SyncRevisionConflict {
  entity: SyncEntity;
  id: string;
  clientBaseRevision: number | null;
  serverRevision: number | null;
  record: Record<string, unknown> | null;
}

export interface SyncChangeRecord {
  sequence: number;
  vaultId: string;
  entity: SyncEntity;
  entityId: string;
  action: "upsert" | "delete" | "reset";
  revision: number | null;
  transactionId: string;
  record: Record<string, unknown> | null;
}

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
  revision?: number;
  summaryRevision?: number;
  transcriptRevision?: number;
}

export interface SyncMeetingCursor {
  createdAt: Date;
  meetingId: string;
}

export interface SyncScreenshotCursor {
  capturedAt: Date;
  screenshotId: string;
}

export interface SyncScreenshotRecord {
  screenshotId: string;
  vaultId: string;
  meetingId: string;
  capturedAt: Date;
  contentType: string;
  storageKey: string;
  contentLength: number;
  contentHash: string;
  ocrText: string | null;
  caption: string | null;
  revision?: number;
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
  lockVault(vaultId: string): Promise<void>;
  commitTransaction(transaction: SyncTransaction): Promise<SyncTransactionResponse>;
  resolveTransaction(transaction: SyncTransaction): Promise<SyncTransactionResponse | null>;
  assertCursorAvailable(vaultId: string, after: number): Promise<void>;
  listSnapshot(vaultId: string, after: SyncSnapshotPosition | undefined, limit: number): Promise<{ items: SyncCanonicalRecord[]; hasMore: boolean }>;
  listChanges(vaultId: string, after: number, through: number, limit: number): Promise<SyncChangeRecord[]>;
  latestChangeSequence(vaultId?: string): Promise<number>;
  ensureUploadTarget(vaultId: string, meetingId: string): Promise<boolean>;
  putTranscriptChunk(
    vaultId: string,
    meetingId: string,
    patchId: string,
    chunkIndex: number,
    contentHash: string,
    segments: SyncTranscriptSegment[],
    deletions: string[],
  ): Promise<boolean>;
  deleteTranscriptPatch(vaultId: string, meetingId: string, patchId: string): Promise<void>;
  getScreenshot(
    vaultId: string,
    meetingId: string,
    screenshotId: string,
    activeOnly?: boolean,
  ): Promise<SyncScreenshotRecord | null>;
  createScreenshot(input: SyncScreenshotRecord): Promise<boolean>;
  discardInactiveScreenshot(vaultId: string, screenshotId: string): Promise<boolean>;
  deleteScreenshot(vaultId: string, screenshotId: string, storageKey: string): Promise<boolean>;
  listOrganizations(): Promise<{ id: string; name: string; slug: string }[]>;
  listVaults(organizationId?: string): Promise<SyncVaultRecord[]>;
  getVault(vaultId: string): Promise<SyncVaultRecord | null>;
  listProjects(vaultId: string): Promise<SyncProjectView[]>;
  getProject(vaultId: string, projectId: string): Promise<SyncProjectView | null>;
  listMeetings(
    vaultId: string,
    query: SyncSearchQuery | undefined,
    limit: number,
    projectId?: string,
    cursor?: SyncMeetingCursor,
    projectScope?: "direct" | "unassigned",
  ): Promise<SyncMeetingRecord[]>;
  getMeeting(vaultId: string, meetingId: string): Promise<SyncMeetingRecord | null>;
  listTranscript(
    vaultId: string,
    meetingId: string,
    limit: number,
    cursor?: SyncTranscriptCursor,
  ): Promise<SyncTranscriptSegment[]>;
  listScreenshots(
    vaultId: string,
    meetingId: string,
    query: SyncSearchQuery | undefined,
    limit: number,
    cursor?: SyncScreenshotCursor,
  ): Promise<SyncScreenshotRecord[]>;
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
  listHistoryTargets(after?: SyncHistoryTarget): Promise<SyncHistoryTarget[]>;
  pruneHistoryBatch(target: SyncHistoryTarget): Promise<SyncRetentionResult>;
  withIdentity<T>(identity: Identity, action: (store: IdentitySyncStore) => Promise<T>): Promise<T>;
  claimStorageDeletes(limit: number): Promise<StorageDeleteClaim[]>;
  hasStorageDelete(storageKey: string): Promise<boolean>;
  enqueueStorageDelete(storageKey: string): Promise<void>;
  isStorageDeleteClaimCurrent(claim: StorageDeleteClaim): Promise<boolean>;
  completeStorageDelete(claim: StorageDeleteClaim): Promise<void>;
  failStorageDelete(claim: StorageDeleteClaim, code: string): Promise<void>;
  withStorageKeyLock<T>(storageKey: string, action: () => Promise<T>): Promise<T>;
}

export interface StorageDeleteClaim {
  storageKey: string;
  attempt: number;
}
