import { projectPublicIDs } from "./public-schema";
import { problemResponse } from "./problem";
import { createRoute, OpenAPIHono, z, type RouteConfig } from "@hono/zod-openapi";
import type { Handler } from "hono";
import type { AppVariables } from "../app";
import { accountSettingsSchema, accountSettingsPatchSchema } from "../account-settings-model";
import { fileUploadSchema, filePatchSchema } from "../files/model";
import { summaryStartSchema } from "../summary/service";
import { vaultSearchRequestSchema } from "../search/model";
import { transcriptChunkSchema } from "../sync/schemas";
import * as S from "./schemas";

const bearer: Record<string, string[]>[] = [{ bearerAuth: [] }, { browserSession: [] }, { trustedProxy: [] }];
const browser: Record<string, string[]>[] = [{ browserSession: [] }, { trustedProxy: [] }];
const problemResponses: RouteConfig["responses"] = { default: {
  description: "Request failed. Use the HTTP status and Problem.code; 409 conflicts require reconciliation before retrying.",
  content: { "application/problem+json": { schema: S.problem } },
  headers: { "WWW-Authenticate": { schema: { type: "string" } }, Allow: { schema: { type: "string" } }, "Retry-After": { schema: { type: "string" } } },
} };
const json = (schema: z.ZodType, description = "Successful response") => ({ description, content: { "application/json": { schema } } });
const empty = { description: "Success; no response body." };
const location = { Location: { description: "URI of the created representation or individual job.", schema: { type: "string" as const } } };
const created = (schema: z.ZodType) => ({ ...json(schema, "Created. An identical replay returns 200."), headers: location });
const accepted = (schema: z.ZodType) => ({ ...json(schema, "Accepted. Poll the individual job at Location."), headers: location });
const binaryHeaders = {
  "Content-Type": { schema: { type: "string" as const } }, "Content-Length": { schema: { type: "integer" as const } },
  "X-Dahlia-Image-Variant": { schema: { type: "string" as const } }, "X-Dahlia-Original-Sha256": { schema: { type: "string" as const } },
  ETag: { schema: { type: "string" as const } }, "Content-Range": { schema: { type: "string" as const } },
  "Accept-Ranges": { schema: { type: "string" as const } }, "Cache-Control": { schema: { type: "string" as const } },
};
const binary = { description: "Streamed bytes. Authorization is checked before conditional responses.",
  content: { "*/*": { schema: z.string().openapi({ format: "binary" }) } }, headers: binaryHeaders };
const binaryResponses = { 200: binary, 206: binary, 304: { description: "Not modified; no body.", headers: binaryHeaders } };
const readHeaders = z.object({ range: z.string().optional(), "if-match": z.string().optional(), "if-none-match": z.string().optional(),
  "if-range": z.string().optional(), "if-modified-since": z.string().optional(), "if-unmodified-since": z.string().optional() });
const uploadHeaders = z.object({ "content-type": z.string(), "content-length": z.string().regex(/^\d+$/), "content-encoding": z.literal("identity").optional() });
const recordingUpload = z.object({ id: S.integer, source: z.enum(["mic", "system"]), contentType: z.literal("audio/mp4"), size: S.integer, checksum: z.string(), revision: S.integer.nullable(), contentUrl: z.string() }).openapi("RecordingUpload");
const jobEnvelope = z.object({ job: S.summaryJob });
const settingsEnvelope = z.object({ settings: accountSettingsSchema.nullable() }).openapi("AccountSettingsResponse");
const admin = S.person.extend({ createdAt: S.date, role: z.literal("admin"), removable: z.boolean() }).openapi("Administrator");
const session = z.object({ id: S.principalId, createdAt: S.date, expiresAt: S.date, userAgent: z.string().nullable(), current: z.boolean() }).openapi("Session");
function pathParameterSchema(name: string) {
  switch (name) {
    case "userId":
    case "organizationId":
    case "teamId":
      return S.principalId;
    case "variant":
      return z.enum(["thumb_480", "thumb_1280", "thumb_1568", "thumb_1920"]);
    case "version":
    case "recordingId":
      return z.string().regex(/^[1-9][0-9]*$/);
    case "chunkIndex":
      return z.string().regex(/^\d+$/);
    case "source":
      return z.enum(["mic", "system"]);
    default:
      return S.id;
  }
}
const params = (path: string) => z.object(Object.fromEntries(
  [...path.matchAll(/\{(\w+)\}/g)].map(([, name]) => [name!, pathParameterSchema(name!)]),
));
function route(method: RouteConfig["method"], path: string, operationId: string, summary: string,
  responses: RouteConfig["responses"], request: RouteConfig["request"] = {}, security?: Record<string, string[]>[]) {
  return createRoute({ method, path, operationId, summary, tags: [path.split("/")[3] ?? "system"], security,
    request: { params: params(path), query: z.object({}).strict(), ...request }, responses: { ...problemResponses, ...responses },
  });
}
const body = (schema: z.ZodType, example?: unknown) => ({ body: { required: true, content: { "application/json": { schema, ...(example === undefined ? {} : { example }) } } } });
const uploadBody = { body: { required: true, content: { "application/octet-stream": { schema: z.string().openapi({ format: "binary" }) } } }, headers: uploadHeaders };
const m = "/api/v1/meetings/{meetingId}";
const v = "/api/v1/vaults/{vaultId}";
const o = "/api/v1/organizations/{organizationId}";
const j = `${m}/summary-jobs`;
export type OperationId =
  "getHealth" | "getOpenAPI" | "getSession" | "listSessions" | "revokeSession"
  | "listAdministrators" | "addAdministrator" | "removeAdministrator" | "listServerUsers" | "listServerOrganizations"
  | "getSettings" | "updateSettings" | "getCapabilities" | "listVaults" | "getVault"
  | "listProjects" | "getProject" | "listMeetings" | "getMeeting" | "listSummaries"
  | "getSummary" | "getLatestSummary" | "listTranscripts" | "getTranscript" | "getLatestTranscript"
  | "startSummaryJob" | "getLatestSummaryJob" | "getSummaryJob" | "cancelSummaryJob" | "retrySummaryJob"
  | "commitTransaction" | "resolveTransaction" | "getChanges" | "getSnapshot" | "search"
  | "putLiveTranscript" | "getLiveTranscript" | "listLiveMeetings" | "getLiveTranscriptEvents"
  | "textSearch" | "getEvents" | "putTranscriptChunk" | "reserveFileUpload" | "putFileContent"
  | "getFile" | "updateFile" | "listFiles" | "listMeetingFiles" | "getFileContent"
  | "headFileContent" | "getFileVariant" | "headFileVariant" | "putRecordingContent" | "listRecordings"
  | "getRecordingContent" | "headRecordingContent" | "getTransferAudience" | "transferVault" | "getRelocations"
  | "listPermissions" | "putOrganizationPermission" | "deleteOrganizationPermission" | "putTeamPermission" | "deleteTeamPermission"
  | "listOrganizations" | "getOrganization" | "listOrganizationMembers" | "listTeams" | "createTeam"
  | "updateTeam" | "deleteTeam" | "listTeamMembers" | "putTeamMember" | "deleteTeamMember";
export const contracts: Record<OperationId, RouteConfig & { operationId: string }> = {
  getHealth: createRoute({ method: "get", path: "/healthz", operationId: "getHealth", security: [], summary: "Process health", responses: { 200: json(z.object({ status: z.literal("ok") })) } }),
  getOpenAPI: createRoute({ method: "get", path: "/openapi.json", operationId: "getOpenAPI", security: [], summary: "Public OpenAPI 3.1 contract", responses: { 200: json(z.looseObject({ openapi: z.literal("3.1.0"), info: z.looseObject({ title: z.string(), version: z.string() }), paths: z.record(z.string(), z.unknown()) })) } }),
  getSession: route("get", "/api/v1/session", "getSession", "Current browser identity", { 200: json(z.object({
    capabilities: z.object({ admin: z.boolean(), sessions: z.boolean(), sync: z.boolean(), sharing: z.boolean() }).catchall(z.boolean()), user: S.person.partial({ name: true, email: true }),
    workspace: z.object({ id: z.string(), type: z.literal("personal") }),
  }).openapi("CurrentSession")) }, {}, browser),
  listSessions: route("get", "/api/v1/sessions", "listSessions", "OAuth sessions (accounts mode only)", { 200: json(S.page(session)) }, {}, browser),
  revokeSession: route("delete", "/api/v1/sessions/{id}", "revokeSession", "Revoke an OAuth session", { 204: empty }, { params: z.object({ id: S.principalId }) }, browser),
  listAdministrators: route("get", "/api/v1/admin/members", "listAdministrators", "List platform administrators; administrator only", { 200: json(S.page(admin)) }, {}, browser),
  addAdministrator: route("post", "/api/v1/admin/members", "addAdministrator", "Grant administrator access to an existing user", { 201: created(admin) }, body(z.object({ email: z.string().trim().pipe(z.email()).openapi({ format: "email", example: "person@example.com" }) }).strict()), browser),
  removeAdministrator: route("delete", "/api/v1/admin/members/{userId}", "removeAdministrator", "Revoke administrator access; retain the last administrator", { 204: empty }, {}, browser),
  listServerUsers: route("get", "/api/v1/admin/users", "listServerUsers", "Administrator directory; ordered by name and ID", { 200: json(z.object({ items: z.array(S.person.extend({ createdAt: S.date, role: z.string().nullable() })), hasMore: z.boolean() })) }, { query: z.object({ offset: z.string().regex(/^\d+$/).optional().openapi({ description: "0–1000000. Fixed page size 100." }) }).strict() }, browser),
  listServerOrganizations: route("get", "/api/v1/admin/organizations", "listServerOrganizations", "Administrator organization directory", { 200: json(z.object({ items: z.array(S.organization.extend({ memberCount: S.integer, teamCount: S.integer })), hasMore: z.boolean() })) }, { query: z.object({ offset: z.string().regex(/^\d+$/).optional() }).strict() }, browser),
  getSettings: route("get", "/api/v1/account/settings", "getSettings", "Read current account settings", { 200: json(settingsEnvelope) }),
  updateSettings: route("patch", "/api/v1/account/settings", "updateSettings", "Merge supplied fields, including nested summary settings; maximum 8 KiB", { 200: json(settingsEnvelope) }, body(accountSettingsPatchSchema, { outputLanguage: "ja" })),
  getCapabilities: route("get", "/api/v1/capabilities", "getCapabilities", "Discover feature versions; unsupported features are omitted", { 200: json(S.capabilities) }),
  listVaults: route("get", "/api/v1/vaults", "listVaults", "Accessible Vaults", { 200: json(S.page(S.vault)) }, { query: z.object({ owner: S.principalId.optional(), organizationId: S.principalId.optional() }).strict() }),
  getVault: route("get", v, "getVault", "Get Vault", { 200: json(S.vault) }),
  listProjects: route("get", `${v}/projects`, "listProjects", "Vault project tree", { 200: json(S.page(S.project)) }),
  getProject: route("get", "/api/v1/projects/{projectId}", "getProject", "Resolve and get an accessible Project", { 200: json(S.project) }),
  listMeetings: route("get", `${v}/meetings`, "listMeetings", "Meetings by creation time and ID; 200 per page", { 200: json(S.page(S.meeting)) }, { query: S.pageQuery.extend({ query: z.string().max(500).optional(), projectId: S.id.optional(), projectScope: z.enum(["direct", "unassigned"]).optional() }).strict() }),
  getMeeting: route("get", m, "getMeeting", "Resolve and get meeting metadata", { 200: json(S.meeting) }),
  listSummaries: route("get", `${m}/summaries`, "listSummaries", "Summary versions, newest first; bodies omitted", { 200: json(S.page(S.summary.omit({ document: true }))) }, { query: S.historyQuery }),
  getSummary: route("get", `${m}/summaries/{version}`, "getSummary", "Read a saved summary version", { 200: json(S.summary) }),
  getLatestSummary: route("get", `${m}/summaries/latest`, "getLatestSummary", "Current summary; present=false when absent", { 200: json(S.latestSummary) }, { query: S.manifestQuery }),
  listTranscripts: route("get", `${m}/transcripts`, "listTranscripts", "Transcript versions, newest first", { 200: json(S.page(S.transcript)) }, { query: S.historyQuery }),
  getTranscript: route("get", `${m}/transcripts/{version}`, "getTranscript", "Read a transcript version in bounded pages", { 200: json(S.transcriptContent) }, { query: S.contentQuery }),
  getLatestTranscript: route("get", `${m}/transcripts/latest`, "getLatestTranscript", "Read current transcript; match version and syncRevision across pages", { 200: json(S.transcriptContent) }, { query: S.contentQuery }),
  startSummaryJob: route("post", j, "startSummaryJob", "Queue an owner-only summary job; ID is the replay key; maximum 8 KiB", { 202: accepted(jobEnvelope) }, body(summaryStartSchema)),
  getLatestSummaryJob: route("get", `${j}/latest`, "getLatestSummaryJob", "Most recent owner-visible job, or null", { 200: json(z.object({ job: z.object(S.summaryJob.shape).nullable() })) }),
  getSummaryJob: route("get", `${j}/{jobId}`, "getSummaryJob", "Get an individual owner-visible job", { 200: json(jobEnvelope) }),
  cancelSummaryJob: route("post", `${j}/{jobId}/cancel`, "cancelSummaryJob", "Cancel a job; repeated cancellation is safe", { 200: json(jobEnvelope) }),
  retrySummaryJob: route("post", `${j}/{jobId}/retry`, "retrySummaryJob", "Retry a failed or cancelled job using a new ID", { 202: accepted(jobEnvelope) }, body(z.object({ id: z.uuidv7().meta({ format: "uuidv7" }) }).strict())),
  commitTransaction: route("post", "/api/v1/transactions", "commitTransaction", "Commit one atomic Vault transaction; maximum 8 MiB", { 200: json(S.receipt) }, body(S.transaction)),
  resolveTransaction: route("post", "/api/v1/transactions/resolve", "resolveTransaction", "Resolve the exact original request without mutating; never advance the pull cursor from receipts", { 200: json(S.resolution) }, body(S.transaction)),
  getChanges: route("get", `${v}/changes`, "getChanges", "Durable delta feed; retain highWaterCursor across a catch-up", { 200: json(S.changes) }, { query: S.pageQuery.extend({ highWaterCursor: S.cursor.optional() }).strict() }),
  getSnapshot: route("get", `${v}/snapshot`, "getSnapshot", "Bounded snapshot; retain startCursor and catch up before reconciliation", { 200: json(S.snapshot) }, { query: S.pageQuery.extend({ startCursor: S.cursor.optional() }).strict() }),
  search: route("post", `${v}/search`, "search", "Ranked search with explicit truncation indicators; maximum 16 KiB", { 200: json(S.searchResults) }, body(vaultSearchRequestSchema)),
  textSearch: route("post", `${v}/text-search`, "textSearch", "Exhaustive full-text search pages; cursor invalidates when the ledger changes", { 200: json(S.textSearchResults) }, body(S.textSearchRequest)),
  putLiveTranscript: route("put", `${m}/live-transcript`, "putLiveTranscript", "Publish latest owner-only previews; monotonic session sequence, expires after 45 seconds", { 204: empty }, body(S.liveStateInput)),
  getLiveTranscript: route("get", `${m}/live-transcript`, "getLiveTranscript", "Read confirmed speech and replaceable previews", { 200: json(S.liveTranscriptPage) }, { query: S.liveReadQuery }),
  listLiveMeetings: route("get", "/api/v1/vaults/{vaultId}/live-meetings", "listLiveMeetings", "List recently published live sessions", { 200: json(z.object({ meetings: z.array(S.liveState) })) }),
  getLiveTranscriptEvents: route("get", `${m}/live-transcript/events`, "getLiveTranscriptEvents", "SSE live speech; resume by cursor or Last-Event-ID; reset means replace accumulated confirmed speech", { 200: { description: "Live transcript pages as transcript or reset events. Comment heartbeats. Errors terminate the stream.", content: { "text/event-stream": { schema: z.string() } } } }, { query: S.liveReadQuery, headers: z.object({ "last-event-id": z.string().max(2048).optional() }) }),
  getEvents: route("get", "/api/v1/events", "getEvents", "SSE invalidation and account_settings events; recover through canonical reads", { 200: { description: "text/event-stream: invalidation has {cursor}; account_settings has {}. No user content.", content: { "text/event-stream": { schema: z.string() } } } }, { query: z.object({ cursor: S.cursor.optional() }).strict(), headers: z.object({ "last-event-id": z.string().optional() }) }),
  putTranscriptChunk: route("put", `${m}/transcript-uploads/{patchId}/chunks/{chunkIndex}`, "putTranscriptChunk", "Stage an owner-only transcript patch chunk; SHA-256 of exact request bytes", { 204: empty }, { ...body(transcriptChunkSchema), headers: z.object({ "x-dahlia-content-sha256": z.string().regex(/^[a-fA-F0-9]{64}$/) }) }, [{ bearerAuth: [] }, { trustedProxy: [] }]),
  reserveFileUpload: route("post", "/api/v1/file-uploads", "reserveFileUpload", "Reserve private file staging with a client-generated UUIDv7; maximum 8 KiB", { 201: created(S.file), 200: json(S.file) }, body(fileUploadSchema)),
  putFileContent: route("put", "/api/v1/file-uploads/{fileId}/content", "putFileContent", "Stream reserved file bytes; identical replay succeeds, different content conflicts", { 201: created(S.file), 200: json(S.file) }, uploadBody),
  getFile: route("get", "/api/v1/files/{fileId}", "getFile", "File JSON metadata; staged files are owner-only", { 200: json(S.file) }),
  updateFile: route("patch", "/api/v1/files/{fileId}", "updateFile", "Owner metadata patch with baseRevision; maximum 128 KiB", { 200: json(S.file) }, body(filePatchSchema)),
  listFiles: route("get", `${v}/files`, "listFiles", "Committed files by ID; 200 per page", { 200: json(S.page(S.file)) }, { query: S.pageQuery }),
  listMeetingFiles: route("get", `${m}/files`, "listMeetingFiles", "Meeting file links by ID; 200 per page", { 200: json(S.page(S.meetingFile.extend({ file: S.file }))) }, { query: S.pageQuery }),
  getFileContent: route("get", "/api/v1/files/{fileId}/content", "getFileContent", "Stream original file", binaryResponses, { headers: readHeaders }),
  headFileContent: route("head", "/api/v1/files/{fileId}/content", "headFileContent", "File headers; Range ignored; no body", { 200: { description: "Full representation headers", headers: binaryHeaders }, 304: empty }, { headers: readHeaders }),
  getFileVariant: route("get", "/api/v1/files/{fileId}/variants/{variant}", "getFileVariant", "Stream image variant", binaryResponses, { headers: readHeaders }),
  headFileVariant: route("head", "/api/v1/files/{fileId}/variants/{variant}", "headFileVariant", "Variant headers; Range ignored; no body", { 200: { description: "Full representation headers", headers: binaryHeaders }, 304: empty }, { headers: readHeaders }),
  putRecordingContent: route("put", `${m}/recording-uploads/{sessionId}/audio/{source}`, "putRecordingContent", "Stage audio/mp4; maximum 1 GiB; Transaction activates the recording", {
    201: created(recordingUpload),
    200: json(recordingUpload),
  }, { ...uploadBody, body: { required: true, content: { "audio/mp4": { schema: z.string().openapi({ format: "binary" }) } } } }),
  listRecordings: route("get", `${m}/recordings`, "listRecordings", "Committed recordings by meeting-local number; 200 per page", { 200: json(S.page(S.recording)) }, { query: S.pageQuery }),
  getRecordingContent: route("get", `${m}/recordings/{recordingId}/audio/{source}`, "getRecordingContent", "Stream recording audio", { ...binaryResponses, 200: { ...binary, content: { "audio/mp4": { schema: z.string().openapi({ format: "binary" }) } } }, 206: { ...binary, content: { "audio/mp4": { schema: z.string().openapi({ format: "binary" }) } } } }, { headers: readHeaders }),
  headRecordingContent: route("head", `${m}/recordings/{recordingId}/audio/{source}`, "headRecordingContent", "Recording headers; Range ignored; no body", { 200: { description: "Full representation headers", headers: binaryHeaders }, 304: empty }, { headers: readHeaders }),
  getTransferAudience: route("get", `${v}/transfer-audience`, "getTransferAudience", "Preview readers gaining or losing access; owner only", { 200: json(z.object({ audienceHash: z.string(), removed: z.array(S.person), added: z.array(S.person) })) }, { query: z.object({ destinationVaultId: S.id }).strict() }),
  transferVault: route("post", `${v}/transfer`, "transferVault", "Move all content after revision and audience checks; owner only", { 200: json(z.object({ id: S.id, status: z.literal("committed"), sourceVaultId: S.id, destinationVaultId: S.id })) }, { ...body(z.object({ destinationVaultId: S.id, sourceRevision: S.integer, destinationRevision: S.integer, audienceHash: z.string().regex(/^[a-f0-9]{64}$/) }).strict()), headers: z.object({ "idempotency-key": z.uuidv7().meta({ format: "uuidv7" }) }) }),
  getRelocations: route("get", `${v}/relocations`, "getRelocations", "Resolve moved resources to currently accessible Vaults", { 200: json(z.object({ vaults: z.array(S.vault), items: z.array(z.object({ entity: z.enum(["project", "meeting", "file"]), id: S.id, vaultId: S.id })) })) }),
  listPermissions: route("get", `${v}/permissions`, "listPermissions", "Read Vault sharing permissions", { 200: json(S.page(S.permission)) }, {}, browser),
  putOrganizationPermission: route("put", `${v}/permissions/organizations/{organizationId}`, "putOrganizationPermission", "Grant read-only organization access; owner only", { 204: empty }, {}, browser),
  deleteOrganizationPermission: route("delete", `${v}/permissions/organizations/{organizationId}`, "deleteOrganizationPermission", "Revoke organization access; owner only", { 204: empty }, {}, browser),
  putTeamPermission: route("put", `${v}/permissions/teams/{teamId}`, "putTeamPermission", "Grant read-only team access; owner only", { 204: empty }, {}, browser),
  deleteTeamPermission: route("delete", `${v}/permissions/teams/{teamId}`, "deleteTeamPermission", "Revoke team access; owner only", { 204: empty }, {}, browser),
  listOrganizations: route("get", "/api/v1/organizations", "listOrganizations", "Current organization memberships", { 200: json(S.page(S.organization)) }),
  getOrganization: route("get", o, "getOrganization", "External organization (header mode only)", { 200: json(S.organization) }, {}, browser),
  listOrganizationMembers: route("get", `${o}/members`, "listOrganizationMembers", "External organization members (header mode only)", { 200: json(S.page(z.object({ id: S.principalId, userId: S.principalId, role: z.string(), user: S.person.omit({ id: true }) }))) }, {}, browser),
  listTeams: route("get", `${o}/teams`, "listTeams", "External teams (header mode only)", { 200: json(S.page(S.team)) }, {}, browser),
  createTeam: route("post", `${o}/teams`, "createTeam", "Create external team (header mode only)", { 201: created(S.team) }, body(z.object({ name: z.string().trim().min(1).max(100) }).strict()), browser),
  updateTeam: route("patch", `${o}/teams/{teamId}`, "updateTeam", "Rename external team (header mode only)", { 200: json(S.team) }, body(z.object({ name: z.string().trim().min(1).max(100) }).strict()), browser),
  deleteTeam: route("delete", `${o}/teams/{teamId}`, "deleteTeam", "Delete external team (header mode only)", { 204: empty }, {}, browser),
  listTeamMembers: route("get", `${o}/teams/{teamId}/members`, "listTeamMembers", "External team members (header mode only)", { 200: json(S.page(S.person.omit({ id: true }).extend({ id: S.principalId, userId: S.principalId, teamId: S.principalId }).openapi("TeamMember"))) }, {}, browser),
  putTeamMember: route("put", `${o}/teams/{teamId}/members/{userId}`, "putTeamMember", "Add an organization member to an external team", { 204: empty }, {}, browser),
  deleteTeamMember: route("delete", `${o}/teams/{teamId}/members/{userId}`, "deleteTeamMember", "Remove an external team member", { 204: empty }, {}, browser),
};

/** The route owns request validation and documentation; service methods own business validation.
 * Response bodies are verified against these same schemas by the API contract tests. */
export function registerApi(app: OpenAPIHono<{ Variables: AppVariables }>, operation: OperationId, ...handlers: Handler<{ Variables: AppVariables }>[]) {
  const contract = contracts[operation];
  const handler = handlers.at(-1)!;
  const validate: Handler<{ Variables: AppVariables }> = async (context, next) => {
    const query = new URL(context.req.url).searchParams;
    if ([...query.keys()].some((key) => query.getAll(key).length !== 1)) return problemResponse(400, "duplicate_query_parameter");
    const content = (contract as RouteConfig).request?.body?.content;
    if (content && "application/json" in content && context.req.header("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json") {
      return problemResponse(415, "unsupported_media_type");
    }
    await next();
  };
  app.openapi({ ...contract, middleware: [...handlers.slice(0, -1), validate] }, handler as never);
}
export function openapiDocument(): ReturnType<OpenAPIHono["getOpenAPI31Document"]> {
  const app = new OpenAPIHono();
  for (const [name, schema] of Object.entries({ Vault: S.vault, Project: S.project, Meeting: S.meeting, File: S.file, Transcript: S.transcript, Summary: S.summary, Recording: S.recording })) app.openAPIRegistry.register(name, schema);
  for (const contract of Object.values(contracts)) app.openAPIRegistry.registerPath(contract);
  app.openAPIRegistry.registerComponent("securitySchemes", "bearerAuth", { type: "http", scheme: "bearer", description: "Dahlia OAuth access token with all-apis scope." });
  app.openAPIRegistry.registerComponent("securitySchemes", "browserSession", { type: "apiKey", in: "cookie", name: "__Secure-better-auth.session_token", description: "Better Auth session (development uses better-auth.session_token). Mutations require the configured Origin." });
  app.openAPIRegistry.registerComponent("securitySchemes", "trustedProxy", { type: "apiKey", in: "header", name: "X-Forwarded-Email", description: "Header auth mode only; configured identity header from a trusted proxy. Direct client-supplied identity is forbidden." });
  const document = app.getOpenAPI31Document({ openapi: "3.1.0", security: bearer, info: { title: "Dahlia Server API", version: "1.0.0", description: "Dahlia-owned HTTP API. OAuth, OpenAI Responses, and MCP preserve their native protocols; see the API audit for delegated operations. Current resource access is checked on every request. Browser mutations require the configured same origin; trustedProxy is valid only behind a verified identity proxy. Unsupported deployment capabilities are reported by /api/v1/capabilities." }, servers: [{ url: "/" }] });
  for (const contract of Object.values(contracts)) {
    const operation = document.paths?.[contract.path]?.[contract.method as "get"];
    if (!operation?.responses?.default) continue;
    document.components = { ...document.components, responses: { Problem: operation.responses.default } };
    operation.responses.default = { $ref: "#/components/responses/Problem" };
  }
  projectPublicIDs(document);
  return document;
}
