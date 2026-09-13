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

export interface SyncWorkspaceRecord {
  organizationId: string;
  encryption?: "none" | "server";
  hasResources?: boolean;
  icon?: string | null;
  color?: string | null;
  workspaceId: string;
  name: string;
  revision?: number;
  createdAt: Date;
  updatedAt: Date;
  role: WorkspaceRole;
}

export interface SyncProjectRecord {
  icon?: string | null;
  color?: string | null;
  projectId: string;
  workspaceId: string;
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

export type WorkspaceRole = "admin" | "editor" | "viewer";
export type WorkspacePrincipalType = "user" | "organization" | "team";
export type SyncEntity = "workspace" | "project" | "meeting" | "summary" | "transcript" | "file" | "meeting_attachment" | "meeting_event" | "recording";
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
  schemaVersion: 3;
  id: string;
  workspaceId: string;
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
  workspaceId: string;
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
  workspaceId: string;
  entity: SyncEntity;
  entityId: string;
  action: "upsert" | "delete" | "reset";
  revision: number | null;
  transactionId: string;
  record: Record<string, unknown> | null;
}

export interface WorkspacePermissionRecord {
  workspaceId: string;
  principalType: WorkspacePrincipalType;
  principalId: string;
  role: WorkspaceRole;
  createdAt: Date;
}

export interface SyncMeetingRecord {
  meetingId: string;
  workspaceId: string;
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
  workspaceId: string;
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

export interface WorkspaceRelocations {
  workspaces: SyncWorkspaceRecord[];
  items: { entity: "project" | "meeting" | "file"; id: string; workspaceId: string }[];
}

export interface WorkspaceTransferRequest {
  sourceWorkspaceId: string;
  destinationWorkspaceId: string;
  sourceRevision: number;
  destinationRevision: number;
  audienceHash: string;
  idempotencyKey: string;
  requestHash: string;
}

export interface WorkspaceTransferRecord {
  sequence: number;
  id: string;
  sourceWorkspaceId: string;
  destinationWorkspaceId: string;
  manifest: { projects: string[]; meetings: string[]; files: string[] };
}

export interface GovernanceWorkspace { workspaceId: string; name: string; revision: number; creatorId: string }

export interface IdentitySyncStore {
  listGovernanceWorkspaces(organizationId: string, after?: string): Promise<{ items: GovernanceWorkspace[]; nextCursor: string | null }>;
  confirmWorkspaceDeletion(organizationId: string, workspaceId: string): Promise<GovernanceWorkspace & { changeCursor: string }>;
  forceDeleteWorkspace(organizationId: string, transaction: SyncTransaction, revision: number, changeCursor: string): Promise<SyncTransactionResponse>;


  workspaceTransferAudience(sourceWorkspaceId: string, destinationWorkspaceId: string): Promise<{ audienceHash: string; removed: { id: string; name: string; email: string }[]; added: { id: string; name: string; email: string }[] }>;
  transferWorkspace(request: WorkspaceTransferRequest): Promise<WorkspaceTransferRecord>;
  getWorkspaceRelocations(workspaceId: string): Promise<WorkspaceRelocations>;
  listSummaryVersions(workspaceId: string, meetingId: string, limit: number, before?: number): Promise<Omit<SummaryVersion, "document">[]>;
  getSummaryVersion(workspaceId: string, meetingId: string, version?: number): Promise<SummaryVersion | null>;
  getSummaryJob(workspaceId: string, meetingId: string, id?: string): Promise<SummaryJob | null>;
  insertSummaryJob(job: SummaryJob): Promise<void>;
  cancelSummaryJob(workspaceId: string, meetingId: string, id: string): Promise<SummaryJob | null>;
  completeSummaryTranscript(job: SummaryJob, transaction: SyncTransaction, transcriptId: string): Promise<TranscriptVersion | null>;
  completeSummaryJob(job: SummaryJob, transaction: SyncTransaction): Promise<boolean>;
  loadImageAnalysis(claim: ImageAnalysisClaim): Promise<ImageAnalysisInput | null>;
  completeImageAnalysis(input: ImageAnalysisInput, transaction: SyncTransaction): Promise<boolean>;
  reserveRecording(workspaceId: string, meetingId: string, sessionId: string, source: RecordingSource): Promise<RecordingRecord>;
  getRecording(meetingId: string, number: number, ownerOnly?: boolean): Promise<RecordingRecord | null>;
  markRecordingUploaded(sessionId: string, source: RecordingSource, generation: string, size: number, checksum: string): Promise<RecordingRecord | null>;
  hasPendingRecordings(meetingId: string): Promise<boolean>;
  listRecordings(meetingId: string, after: number, limit: number): Promise<RecordingRecord[]>;
  expireRecordingUploads(workspaceId: string, before: Date): Promise<void>;

  getTranscript(workspaceId: string, meetingId: string, revision?: number): Promise<TranscriptVersion | null>;
  listTranscriptVersions(workspaceId: string, meetingId: string, limit: number, before?: number): Promise<TranscriptVersion[]>;
  listTranscriptAnalytics(workspaceId: string, meetingId: string, version: number): Promise<TranscriptAnalyticsSegment[]>;
  countTranscript(workspaceId: string, meetingId: string): Promise<number>;
  searchTextPage(workspaceId: string, query: SyncSearchQuery, kind: "meeting" | "screenshot", offset: number, limit: number): Promise<{
    id: string; meetingId: string; snippet: string;
  }[]>;
  lockWorkspace(workspaceId: string): Promise<void>;
  commitTransaction(transaction: SyncTransaction): Promise<SyncTransactionResponse>;
  resolveTransaction(transaction: SyncTransaction): Promise<SyncTransactionResponse | null>;
  assertCursorAvailable(workspaceId: string, after: number): Promise<void>;
  listSnapshot(workspaceId: string, after: SyncSnapshotPosition | undefined, limit: number): Promise<{ items: SyncCanonicalRecord[]; hasMore: boolean }>;
  listChanges(workspaceId: string, after: number, through: number, limit: number): Promise<SyncChangeRecord[]>;
  latestChangeSequence(workspaceId?: string): Promise<number>;
  ensureUploadTarget(workspaceId: string, meetingId: string): Promise<boolean>;
  putTranscriptChunk(
    workspaceId: string,
    meetingId: string,
    patchId: string,
    chunkIndex: number,
    contentHash: string,
    segments: SyncTranscriptSegment[],
    deletions: string[],
  ): Promise<boolean>;
  deleteTranscriptPatch(workspaceId: string, meetingId: string, patchId: string): Promise<void>;
  getScreenshot(
    workspaceId: string,
    meetingId: string,
    screenshotId: string,
    activeOnly?: boolean,
  ): Promise<SyncScreenshotRecord | null>;
  getFile(fileId: string, activeOnly?: boolean): Promise<FileRecord | null>;
  reserveFile(input: FileRecord): Promise<FileRecord | null>;
  markFileUploaded(file: FileRecord, size: number, checksum: string): Promise<FileRecord | null>;
  expireFileUploads(workspaceId: string, before: Date): Promise<void>;
  listFiles(workspaceId: string, after: string | undefined, limit: number): Promise<FileRecord[]>;
  listMeetingAttachments(workspaceId: string, meetingId: string, after: string | undefined, limit: number): Promise<(MeetingAttachmentRecord & { file: FileRecord })[]>;
  listOrganizations(): Promise<{ id: string; name: string; slug: string; kind: string }[]>;
  listWorkspaces(organizationId?: string): Promise<SyncWorkspaceRecord[]>;
  getWorkspace(workspaceId: string): Promise<SyncWorkspaceRecord | null>;
  listProjects(workspaceId: string): Promise<SyncProjectView[]>;
  searchProjectActivity(workspaceId: string, filters: SyncSearchFilters): Promise<{ projectId: string | null; updatedAt: string }[]>;
  resolveEntityWorkspace(entity: "meeting" | "project", id: string): Promise<string | null>;
  getProject(workspaceId: string, projectId: string): Promise<SyncProjectView | null>;
  listMeetings(
    workspaceId: string,
    query: SyncSearchQuery | undefined,
    limit: number,
    projectId?: string,
    cursor?: SyncMeetingCursor,
    projectScope?: "direct" | "unassigned",
    filters?: SyncSearchFilters,
  ): Promise<SyncMeetingRecord[]>;
  getMeeting(workspaceId: string, meetingId: string): Promise<SyncMeetingRecord | null>;
  listTranscript(
    workspaceId: string,
    meetingId: string,
    limit: number | undefined,
    cursor?: SyncTranscriptCursor,
    version?: number,
  ): Promise<SyncTranscriptSegment[]>;
  listScreenshots(
    workspaceId: string,
    meetingId: string | undefined,
    query: SyncSearchQuery | undefined,
    limit: number,
    cursor?: SyncScreenshotCursor,
    filters?: SyncSearchFilters,
  ): Promise<SyncScreenshotRecord[]>;
  searchPermissionTargets(workspaceId: string, query: string, offset: number): Promise<{ items: Array<{ principalType: WorkspacePrincipalType; principalId: string; name: string; detail: string }>; nextCursor: string | null } | null>;
  listPermissions(workspaceId: string): Promise<WorkspacePermissionRecord[] | null>;
  putPermission(workspaceId: string, principalType: WorkspacePrincipalType, principalId: string, role: WorkspaceRole): Promise<boolean>;
  deletePermission(workspaceId: string, principalType: WorkspacePrincipalType, principalId: string): Promise<boolean>;
}

export interface MeetingSyncStore {
  expireRecordingUploads(workspaceId: string, before: Date): Promise<void>;
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
