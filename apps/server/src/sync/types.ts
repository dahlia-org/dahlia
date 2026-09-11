import type { CalendarEventSnapshot } from "./schemas";
import type { TranscriptVersion } from "./transcript";
import type { SummaryVersion } from "../summary/metadata";
import type { SummaryJob } from "../summary/model";
import type { RecordingRecord, RecordingSource } from "../recordings/model";
import type { FileRecord, MeetingAttachmentRecord } from "../files/model";
import type { Identity } from "../auth/identity";
import type { ImageAnalysisClaim, ImageAnalysisInput } from "../image-analysis/model";

export interface SyncTranscriptSegment {
  segmentId: string;
  startedAt: Date;
  endedAt: Date | null;
  text: string;
  createdAt: Date | null;
  audioSource: string | null;
  speakerLabel: string | null;
}

export interface TranscriptAnalyticsSegment {
  segmentId: string;
  startedAt: Date;
  endedAt: Date | null;
  audioSource: string | null;
  normalizedCharacterCount: number;
}

export interface SyncTranscriptCursor {
  startedAt: Date;
  segmentId: string;
}

export interface SyncVaultRecord {
  encryption?: "none" | "server";
  hasResources?: boolean;
  icon?: string | null;
  color?: string | null;
  vaultId: string;
  name: string;
  revision?: number;
  createdAt: Date;
  updatedAt: Date;
  role: VaultRole;
}

export interface SyncProjectRecord {
  icon?: string | null;
  color?: string | null;
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
export type SyncEntity = "vault" | "project" | "meeting" | "summary" | "transcript" | "file" | "meeting_attachment" | "meeting_event" | "recording";
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
  schemaVersion: 2;
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
  entity: Exclude<SyncEntity, "meeting_event">;
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
  icalUid?: string | null;
  recurrenceId?: string | null;
  calendarEvent?: CalendarEventSnapshot | null;
  isRecording?: boolean;
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
  fileId: string;
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

export interface SyncSearchFilters {
  meetingIds?: string[];
  projectIds?: string[];
  from?: Date;
  to?: Date;
  unassigned?: boolean;
}

export interface SyncSearchQuery {
  filters?: SyncSearchFilters;
  text: string;
  tokens: string[];
  ftsCandidateIds?: string[];
  embedding?: {
    model: string;
    dimensions: number;
    vector: number[];
  };
}

export interface VaultRelocations {
  vaults: SyncVaultRecord[];
  items: { entity: "project" | "meeting" | "file"; id: string; vaultId: string }[];
}

export interface VaultTransferRequest {
  sourceVaultId: string;
  destinationVaultId: string;
  sourceRevision: number;
  destinationRevision: number;
  audienceHash: string;
  idempotencyKey: string;
  requestHash: string;
}

export interface VaultTransferRecord {
  sequence: number;
  id: string;
  sourceVaultId: string;
  destinationVaultId: string;
  manifest: { projects: string[]; meetings: string[]; files: string[] };
}

export interface IdentitySyncStore {

  vaultTransferAudience(sourceVaultId: string, destinationVaultId: string): Promise<{ audienceHash: string; removed: { id: string; name: string; email: string }[]; added: { id: string; name: string; email: string }[] }>;
  transferVault(request: VaultTransferRequest): Promise<VaultTransferRecord>;
  getVaultRelocations(vaultId: string): Promise<VaultRelocations>;
  listSummaryVersions(vaultId: string, meetingId: string, limit: number, before?: number): Promise<Omit<SummaryVersion, "document">[]>;
  getSummaryVersion(vaultId: string, meetingId: string, version?: number): Promise<SummaryVersion | null>;
  getSummaryJob(vaultId: string, meetingId: string, id?: string): Promise<SummaryJob | null>;
  insertSummaryJob(job: SummaryJob): Promise<void>;
  cancelSummaryJob(vaultId: string, meetingId: string, id: string): Promise<SummaryJob | null>;
  completeSummaryTranscript(job: SummaryJob, transaction: SyncTransaction, transcriptId: string): Promise<TranscriptVersion | null>;
  completeSummaryJob(job: SummaryJob, transaction: SyncTransaction): Promise<boolean>;
  loadImageAnalysis(claim: ImageAnalysisClaim): Promise<ImageAnalysisInput | null>;
  completeImageAnalysis(input: ImageAnalysisInput, transaction: SyncTransaction): Promise<boolean>;
  reserveRecording(vaultId: string, meetingId: string, sessionId: string, source: RecordingSource): Promise<RecordingRecord>;
  getRecording(meetingId: string, number: number, ownerOnly?: boolean): Promise<RecordingRecord | null>;
  markRecordingUploaded(sessionId: string, source: RecordingSource, generation: string, size: number, checksum: string): Promise<RecordingRecord | null>;
  listRecordings(meetingId: string, after: number, limit: number): Promise<RecordingRecord[]>;
  expireRecordingUploads(vaultId: string, before: Date): Promise<void>;

  getTranscript(vaultId: string, meetingId: string, revision?: number): Promise<TranscriptVersion | null>;
  listTranscriptVersions(vaultId: string, meetingId: string, limit: number, before?: number): Promise<TranscriptVersion[]>;
  listTranscriptAnalytics(vaultId: string, meetingId: string, version: number): Promise<TranscriptAnalyticsSegment[]>;
  countTranscript(vaultId: string, meetingId: string): Promise<number>;
  searchTextPage(vaultId: string, query: SyncSearchQuery, kind: "meeting" | "screenshot", offset: number, limit: number): Promise<{
    id: string; meetingId: string; snippet: string;
  }[]>;
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
  getFile(fileId: string, activeOnly?: boolean): Promise<FileRecord | null>;
  reserveFile(input: FileRecord): Promise<FileRecord | null>;
  markFileUploaded(file: FileRecord, size: number, checksum: string): Promise<FileRecord | null>;
  expireFileUploads(vaultId: string, before: Date): Promise<void>;
  listFiles(vaultId: string, after: string | undefined, limit: number): Promise<FileRecord[]>;
  listMeetingAttachments(vaultId: string, meetingId: string, after: string | undefined, limit: number): Promise<(MeetingAttachmentRecord & { file: FileRecord })[]>;
  listOrganizations(): Promise<{ id: string; name: string; slug: string }[]>;
  listVaults(organizationId?: string, owner?: string): Promise<SyncVaultRecord[]>;
  getVault(vaultId: string): Promise<SyncVaultRecord | null>;
  listProjects(vaultId: string): Promise<SyncProjectView[]>;
  searchProjectActivity(vaultId: string, filters: SyncSearchFilters): Promise<{ projectId: string | null; updatedAt: string }[]>;
  resolveEntityVault(entity: "meeting" | "project", id: string): Promise<string | null>;
  getProject(vaultId: string, projectId: string): Promise<SyncProjectView | null>;
  listMeetings(
    vaultId: string,
    query: SyncSearchQuery | undefined,
    limit: number,
    projectId?: string,
    cursor?: SyncMeetingCursor,
    projectScope?: "direct" | "unassigned",
    filters?: SyncSearchFilters,
  ): Promise<SyncMeetingRecord[]>;
  getMeeting(vaultId: string, meetingId: string): Promise<SyncMeetingRecord | null>;
  listTranscript(
    vaultId: string,
    meetingId: string,
    limit: number | undefined,
    cursor?: SyncTranscriptCursor,
    version?: number,
  ): Promise<SyncTranscriptSegment[]>;
  listScreenshots(
    vaultId: string,
    meetingId: string | undefined,
    query: SyncSearchQuery | undefined,
    limit: number,
    cursor?: SyncScreenshotCursor,
    filters?: SyncSearchFilters,
  ): Promise<SyncScreenshotRecord[]>;
  searchPermissionTargets(vaultId: string, query: string, offset: number): Promise<{ items: Array<{ principalType: VaultPrincipalType; principalId: string; name: string; detail: string }>; nextCursor: string | null } | null>;
  listPermissions(vaultId: string): Promise<VaultPermissionRecord[] | null>;
  putMemberPermission(vaultId: string, principalType: VaultPrincipalType, principalId: string): Promise<boolean>;
  deleteMemberPermission(vaultId: string, principalType: VaultPrincipalType, principalId: string): Promise<boolean>;
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
