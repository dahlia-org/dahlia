# Server API audit

Generated from apps/server/api-audit.json by pnpm openapi:generate. The independently reviewed inventory must match the registered OpenAPI operations. Extensions own their additional routes.

## Dahlia-owned operations

All listed operations use the generated Web and Desktop clients where a bundled consumer exists. Database and sync queue representations are separate from these wire DTOs. Null clears an explicitly nullable property; omitted PATCH properties remain unchanged. Public entity IDs are kind-prefixed TypeIDs; runtime and database models retain UUID/UUIDv7. Integer history versions, recording numbers, OAuth protocol identifiers and opaque cursors keep their own formats. See openapi.json for per-field bounds and ordering.

| Operation | Classification | Method / path | Previous | Reason | Consumers |
| --- | --- | --- | --- | --- | --- |
| getHealth | maintained | GET `/healthz` | `/healthz` | Process health | public API; no bundled caller |
| getOpenAPI | modified | GET `/openapi.json` | `new public contract` | Public OpenAPI 3.1 contract | public API; no bundled caller |
| getSession | modified | GET `/api/v1/session` | `/api/session` | Current browser identity | apps/server/src/client/App.tsx<br>apps/desktop/Sources/Dahlia/Services/DahliaCloudService.swift |
| listSessions | modified | GET `/api/v1/sessions` | `/api/sessions` | OAuth sessions (accounts mode only) | apps/server/src/client/App.tsx |
| revokeSession | modified | DELETE `/api/v1/sessions/{id}` | `/api/sessions/{id}` | Revoke an OAuth session | apps/server/src/client/App.tsx |
| listAdministrators | modified | GET `/api/v1/admin/members` | `/api/admin/members` | List platform administrators; administrator only | apps/server/src/client/App.tsx |
| addAdministrator | modified | POST `/api/v1/admin/members` | `/api/admin/members` | Grant administrator access to an existing user | apps/server/src/client/App.tsx |
| removeAdministrator | modified | DELETE `/api/v1/admin/members/{userId}` | `/api/admin/members/{email}` | Revoke administrator access; retain the last administrator | apps/server/src/client/App.tsx |
| listServerUsers | modified | GET `/api/v1/admin/users` | `/api/admin/users` | Administrator directory; ordered by name and ID | apps/server/src/client/App.tsx |
| listServerOrganizations | modified | GET `/api/v1/admin/organizations` | `/api/admin/organizations` | Administrator organization directory | apps/server/src/client/App.tsx |
| getSettings | maintained | GET `/api/v1/account/settings` | `/api/v1/account/settings` | Read current account settings | apps/server/src/client/SummaryGeneration.tsx<br>apps/desktop/Sources/Dahlia/ViewModels/ServerAccountSettingsModel.swift<br>apps/desktop/Sources/Dahlia/Services/ServerSummaryService.swift |
| updateSettings | maintained | PATCH `/api/v1/account/settings` | `/api/v1/account/settings` | Merge supplied fields, including nested summary settings; maximum 8 KiB | apps/server/src/client/SummaryGeneration.tsx<br>apps/desktop/Sources/Dahlia/ViewModels/CaptionViewModel.swift<br>apps/desktop/Sources/Dahlia/ViewModels/ServerAccountSettingsModel.swift<br>apps/desktop/Sources/Dahlia/Services/AutomaticScreenshotCaptureService.swift |
| getCapabilities | maintained | GET `/api/v1/capabilities` | `/api/v1/capabilities` | Discover feature versions; unsupported features are omitted | apps/server/src/client/SummaryGeneration.tsx<br>apps/desktop/Sources/Dahlia/Database/SearchIndexer.swift<br>apps/desktop/Sources/Dahlia/Services/RecordingArchiveService.swift<br>apps/desktop/Sources/Dahlia/Services/SyncWorker.swift<br>apps/desktop/Sources/Dahlia/Services/ServerSummaryService.swift<br>apps/desktop/Sources/Dahlia/Services/MeetingContentProvider+Search.swift |
| listVaults | modified | GET `/api/v1/vaults` | `/api/v1/vaults` | Accessible Vaults | apps/server/src/client/App.tsx<br>apps/server/src/client/Sidebar.tsx<br>apps/desktop/Sources/Dahlia/ViewModels/BackupSettingsViewModel.swift<br>apps/desktop/Sources/Dahlia/Services/BackupService.swift<br>apps/desktop/Sources/Dahlia/Services/CloudVaultDiscovery.swift |
| getVault | maintained | GET `/api/v1/vaults/{vaultId}` | `/api/v1/vaults/{vaultId}` | Get Vault | apps/server/src/client/App.tsx<br>apps/server/src/client/Sidebar.tsx |
| listProjects | modified | GET `/api/v1/vaults/{vaultId}/projects` | `/api/v1/vaults/{vaultId}/projects` | Vault project tree | apps/server/src/client/App.tsx<br>apps/server/src/client/Search.tsx<br>apps/server/src/client/Sidebar.tsx<br>apps/desktop/Sources/Dahlia/Services/SyncWorker.swift<br>apps/server/src/mcp.ts (shared service; native MCP protocol) |
| getProject | modified | GET `/api/v1/projects/{projectId}` | `/api/v1/vaults/{vaultId}/projects/{projectId} (duplicate scoped route removed; unscoped route retained)` | Resolve and get an accessible Project | apps/server/src/client/App.tsx<br>apps/server/src/mcp.ts (shared service; native MCP protocol) |
| listMeetings | modified | GET `/api/v1/vaults/{vaultId}/meetings` | `/api/v1/vaults/{vaultId}/meetings` | Meetings by creation time and ID; 200 per page | apps/server/src/client/App.tsx<br>apps/server/src/client/Sidebar.tsx<br>apps/server/src/mcp.ts (shared service; native MCP protocol) |
| getMeeting | modified | GET `/api/v1/meetings/{meetingId}` | `/api/v1/vaults/{vaultId}/meetings/{meetingId} (duplicate scoped route removed; unscoped route retained)` | Resolve and get meeting metadata | apps/server/src/client/App.tsx<br>apps/server/src/client/Sidebar.tsx<br>apps/desktop/Sources/Dahlia/Services/SyncWorker.swift<br>apps/server/src/mcp.ts (shared service; native MCP protocol) |
| listSummaries | modified | GET `/api/v1/meetings/{meetingId}/summaries` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/summary` | Summary versions, newest first; bodies omitted | apps/server/src/client/SummaryHistory.tsx |
| getSummary | modified | GET `/api/v1/meetings/{meetingId}/summaries/{version}` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/summary/{version}` | Read a saved summary version | apps/server/src/client/SummaryHistory.tsx |
| getLatestSummary | modified | GET `/api/v1/meetings/{meetingId}/summaries/latest` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/summary/latest` | Current summary; present=false when absent | apps/server/src/client/App.tsx<br>apps/desktop/Sources/Dahlia/Services/MeetingContentProvider.swift |
| listTranscripts | modified | GET `/api/v1/meetings/{meetingId}/transcripts` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/transcript` | Transcript versions, newest first | apps/server/src/client/SummaryGeneration.tsx<br>apps/server/src/client/TranscriptHistory.tsx |
| getTranscript | modified | GET `/api/v1/meetings/{meetingId}/transcripts/{version}` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/transcript/{version}` | Read a transcript version in bounded pages | apps/server/src/client/TranscriptHistory.tsx |
| getLatestTranscript | modified | GET `/api/v1/meetings/{meetingId}/transcripts/latest` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/transcript/latest` | Read current transcript; match version and syncRevision across pages | apps/server/src/client/TranscriptHistory.tsx<br>apps/desktop/Sources/Dahlia/Services/MeetingContentProvider.swift<br>apps/server/src/mcp.ts (shared service; native MCP protocol) |
| startSummaryJob | modified | POST `/api/v1/meetings/{meetingId}/summary-jobs` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/summary` | Queue an owner-only summary job; ID is the replay key; maximum 8 KiB | apps/server/src/client/SummaryGeneration.tsx<br>apps/desktop/Sources/Dahlia/Services/ServerSummaryService.swift |
| getLatestSummaryJob | modified | GET `/api/v1/meetings/{meetingId}/summary-jobs/latest` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/summary/job` | Most recent owner-visible job, or null | apps/server/src/client/SummaryGeneration.tsx<br>apps/desktop/Sources/Dahlia/Services/ServerSummaryService.swift |
| getSummaryJob | modified | GET `/api/v1/meetings/{meetingId}/summary-jobs/{jobId}` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/summary/job?id={jobId}` | Get an individual owner-visible job | apps/desktop/Sources/Dahlia/Services/ServerSummaryService.swift |
| cancelSummaryJob | modified | POST `/api/v1/meetings/{meetingId}/summary-jobs/{jobId}/cancel` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/summary/job/{jobId}/cancel` | Cancel a job; repeated cancellation is safe | apps/server/src/client/SummaryGeneration.tsx<br>apps/desktop/Sources/Dahlia/Services/ServerSummaryService.swift |
| retrySummaryJob | modified | POST `/api/v1/meetings/{meetingId}/summary-jobs/{jobId}/retry` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/summary/job/{jobId}/retry` | Retry a failed or cancelled job using a new ID | apps/server/src/client/SummaryGeneration.tsx<br>apps/desktop/Sources/Dahlia/Services/ServerSummaryService.swift |
| commitTransaction | maintained | POST `/api/v1/transactions` | `/api/v1/transactions` | Commit one atomic Vault transaction; maximum 8 MiB | apps/server/src/client/App.tsx<br>apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| resolveTransaction | maintained | POST `/api/v1/transactions/resolve` | `/api/v1/transactions/resolve` | Resolve the exact original request without mutating; never advance the pull cursor from receipts | apps/server/src/client/App.tsx<br>apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| getChanges | maintained | GET `/api/v1/vaults/{vaultId}/changes` | `/api/v1/vaults/{vaultId}/changes` | Durable delta feed; retain highWaterCursor across a catch-up | apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| getSnapshot | maintained | GET `/api/v1/vaults/{vaultId}/snapshot` | `/api/v1/vaults/{vaultId}/snapshot` | Bounded snapshot; retain startCursor and catch up before reconciliation | apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| search | modified | POST `/api/v1/vaults/{vaultId}/search` | `/api/v1/search (POST body with vaultId)` | Ranked search with explicit truncation indicators; maximum 16 KiB | apps/server/src/client/App.tsx<br>apps/server/src/client/navigation.ts<br>apps/server/src/client/Search.tsx<br>apps/server/src/client/live-data.ts<br>apps/server/src/client/Sidebar.tsx<br>apps/desktop/Sources/Dahlia/Database/TextContentMigration.swift<br>apps/desktop/Sources/Dahlia/Database/EmbeddingGemmaDescriptor.swift<br>apps/desktop/Sources/Dahlia/Database/MeetingRepository+SidebarSearch.swift<br>apps/desktop/Sources/Dahlia/Database/ScreenshotStorageMaintenance.swift<br>apps/desktop/Sources/Dahlia/Database/MeetingRepository+ServerSearch.swift<br>apps/desktop/Sources/Dahlia/Database/MeetingRepository+ScreenshotSearch.swift<br>apps/desktop/Sources/Dahlia/Database/SearchIndexer.swift<br>apps/desktop/Sources/Dahlia/Database/TextContentStore.swift<br>apps/desktop/Sources/Dahlia/ViewModels/SidebarViewModel+Meetings.swift<br>apps/desktop/Sources/Dahlia/Models/MeetingDateGrouping.swift<br>apps/desktop/Sources/Dahlia/Models/MeetingSearch.swift<br>apps/desktop/Sources/Dahlia/Utilities/L10n.swift<br>apps/desktop/Sources/Dahlia/Views/CustomerIntelligenceContactsView.swift<br>apps/desktop/Sources/Dahlia/Views/CustomerIntelligenceTopicsView.swift<br>apps/desktop/Sources/Dahlia/Views/MainWorkspaceHeader.swift<br>apps/desktop/Sources/Dahlia/Views/MainSearchPanel.swift<br>apps/desktop/Sources/Dahlia/Views/CustomerIntelligenceProjectsView.swift<br>apps/desktop/Sources/Dahlia/Views/CustomerIntelligenceInsightsView.swift<br>apps/desktop/Sources/Dahlia/Services/MeetingContentProvider+Broker.swift<br>apps/desktop/Sources/Dahlia/Services/CodexChatService.swift<br>apps/desktop/Sources/Dahlia/Services/SyncWorker.swift<br>apps/desktop/Sources/Dahlia/Services/MeetingContentProvider+Search.swift<br>apps/desktop/Sources/Dahlia/Views/Settings/SettingsCategory.swift<br>apps/desktop/Sources/Dahlia/Views/Settings/SettingsDetailView.swift<br>apps/desktop/Sources/Dahlia/Views/Settings/SettingsGroup.swift<br>apps/desktop/Sources/Dahlia/Views/Debug/ApplicationLogView.swift<br>apps/server/src/mcp.ts (shared service; native MCP protocol) |
| textSearch | modified | POST `/api/v1/vaults/{vaultId}/text-search` | `/api/v1/vaults/{vaultId}/search?q={query} (GET)` | Exhaustive full-text search pages; cursor invalidates when the ledger changes | apps/desktop/Sources/Dahlia/Services/MeetingContentProvider+Search.swift |
| getEvents | maintained | GET `/api/v1/events` | `/api/v1/events` | SSE invalidation and account_settings events; recover through canonical reads | apps/server/src/client/live-data.ts<br>apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| putTranscriptChunk | modified | PUT `/api/v1/meetings/{meetingId}/transcript-uploads/{patchId}/chunks/{chunkIndex}` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/transcript/{patchId}/chunks/{chunkIndex}` | Stage an owner-only transcript patch chunk; SHA-256 of exact request bytes | apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| reserveFileUpload | modified | POST `/api/v1/file-uploads` | `/api/v1/files (POST bytes with query attributes)` | Reserve private file staging with a client-generated UUIDv7; maximum 8 KiB | apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| putFileContent | modified | PUT `/api/v1/file-uploads/{fileId}/content` | `/api/v1/files (POST bytes with query attributes)` | Stream reserved file bytes; identical replay succeeds, different content conflicts | apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| getFile | modified | GET `/api/v1/files/{fileId}` | `/api/v1/files/{fileId}/metadata` | File JSON metadata; staged files are owner-only | apps/server/src/client/App.tsx<br>apps/server/src/client/FileViewer.tsx<br>apps/desktop/Sources/Dahlia/Services/MeetingContentProvider.swift<br>apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| updateFile | modified | PATCH `/api/v1/files/{fileId}` | `/api/v1/files/{fileId}/metadata` | Owner metadata patch with baseRevision; maximum 128 KiB | public API; no bundled caller |
| listFiles | modified | GET `/api/v1/vaults/{vaultId}/files` | `/api/v1/vaults/{vaultId}/files` | Committed files by ID; 200 per page | apps/desktop/Sources/Dahlia/Services/GoogleDriveAPIClient.swift |
| listMeetingFiles | modified | GET `/api/v1/meetings/{meetingId}/files` | `/api/v1/vaults/{vaultId}/meetings/{meetingId}/files` | Meeting file links by ID; 200 per page | apps/server/src/client/App.tsx<br>apps/server/src/mcp.ts (shared service; native MCP protocol) |
| getFileContent | modified | GET `/api/v1/files/{fileId}/content` | `/api/v1/files/{fileId}` | Stream original file | apps/server/src/client/App.tsx<br>apps/server/src/client/Search.tsx<br>apps/server/src/client/FileViewer.tsx<br>apps/desktop/Sources/Dahlia/Services/ScreenshotContentProvider.swift |
| headFileContent | modified | HEAD `/api/v1/files/{fileId}/content` | `/api/v1/files/{fileId}` | File headers; Range ignored; no body | public API; no bundled caller |
| getFileVariant | maintained | GET `/api/v1/files/{fileId}/variants/{variant}` | `/api/v1/files/{fileId}/variants/{variant}` | Stream image variant | apps/server/src/client/Search.tsx<br>apps/desktop/Sources/Dahlia/Services/ScreenshotContentProvider.swift |
| headFileVariant | maintained | HEAD `/api/v1/files/{fileId}/variants/{variant}` | `/api/v1/files/{fileId}/variants/{variant}` | Variant headers; Range ignored; no body | public API; no bundled caller |
| putRecordingContent | modified | PUT `/api/v1/meetings/{meetingId}/recording-uploads/{sessionId}/audio/{source}` | `/api/v1/meetings/{meetingId}/recordings?sessionId={sessionId}&source={source} (POST)` | Stage audio/mp4; maximum 1 GiB; Transaction activates the recording | apps/desktop/Sources/Dahlia/Services/RecordingArchiveService.swift |
| listRecordings | modified | GET `/api/v1/meetings/{meetingId}/recordings` | `/api/v1/meetings/{meetingId}/recordings` | Committed recordings by meeting-local number; 200 per page | apps/server/src/client/SummaryGeneration.tsx<br>apps/desktop/Sources/Dahlia/Services/ServerSummaryService.swift |
| getRecordingContent | maintained | GET `/api/v1/meetings/{meetingId}/recordings/{recordingId}/audio/{source}` | `/api/v1/meetings/{meetingId}/recordings/{recordingId}/audio/{source}` | Stream recording audio | apps/desktop/Sources/Dahlia/Services/RecordingArchiveService.swift |
| headRecordingContent | maintained | HEAD `/api/v1/meetings/{meetingId}/recordings/{recordingId}/audio/{source}` | `/api/v1/meetings/{meetingId}/recordings/{recordingId}/audio/{source}` | Recording headers; Range ignored; no body | public API; no bundled caller |
| getTransferAudience | maintained | GET `/api/v1/vaults/{vaultId}/transfer-audience` | `/api/v1/vaults/{vaultId}/transfer-audience` | Preview readers gaining or losing access; owner only | apps/server/src/client/App.tsx |
| transferVault | maintained | POST `/api/v1/vaults/{vaultId}/transfer` | `/api/v1/vaults/{vaultId}/transfer` | Move all content after revision and audience checks; owner only | apps/server/src/client/App.tsx |
| getRelocations | maintained | GET `/api/v1/vaults/{vaultId}/relocations` | `/api/v1/vaults/{vaultId}/relocations` | Resolve moved resources to currently accessible Vaults | apps/desktop/Sources/Dahlia/Services/SyncWorker.swift |
| listPermissions | modified | GET `/api/v1/vaults/{vaultId}/permissions` | `/api/v1/vaults/{vaultId}/permissions` | Read Vault sharing permissions | apps/server/src/client/App.tsx |
| putOrganizationPermission | maintained | PUT `/api/v1/vaults/{vaultId}/permissions/organizations/{organizationId}` | `/api/v1/vaults/{vaultId}/permissions/organizations/{organizationId}` | Grant read-only organization access; owner only | apps/server/src/client/App.tsx |
| deleteOrganizationPermission | maintained | DELETE `/api/v1/vaults/{vaultId}/permissions/organizations/{organizationId}` | `/api/v1/vaults/{vaultId}/permissions/organizations/{organizationId}` | Revoke organization access; owner only | apps/server/src/client/App.tsx |
| putTeamPermission | maintained | PUT `/api/v1/vaults/{vaultId}/permissions/teams/{teamId}` | `/api/v1/vaults/{vaultId}/permissions/teams/{teamId}` | Grant read-only team access; owner only | apps/server/src/client/App.tsx |
| deleteTeamPermission | maintained | DELETE `/api/v1/vaults/{vaultId}/permissions/teams/{teamId}` | `/api/v1/vaults/{vaultId}/permissions/teams/{teamId}` | Revoke team access; owner only | apps/server/src/client/App.tsx |
| listOrganizations | modified | GET `/api/v1/organizations` | `/api/v1/organizations` | Current organization memberships | apps/server/src/client/App.tsx<br>apps/server/src/client/Sidebar.tsx<br>apps/desktop/Sources/Dahlia/Services/CloudVaultDiscovery.swift |
| getOrganization | maintained | GET `/api/v1/organizations/{organizationId}` | `/api/v1/organizations/{organizationId}` | External organization (header mode only) | public API; no bundled caller |
| listOrganizationMembers | modified | GET `/api/v1/organizations/{organizationId}/members` | `/api/v1/organizations/{organizationId}/members` | External organization members (header mode only) | apps/server/src/client/App.tsx |
| listTeams | modified | GET `/api/v1/organizations/{organizationId}/teams` | `/api/v1/organizations/{organizationId}/teams` | External teams (header mode only) | apps/server/src/client/App.tsx |
| createTeam | maintained | POST `/api/v1/organizations/{organizationId}/teams` | `/api/v1/organizations/{organizationId}/teams` | Create external team (header mode only) | apps/server/src/client/App.tsx |
| updateTeam | maintained | PATCH `/api/v1/organizations/{organizationId}/teams/{teamId}` | `/api/v1/organizations/{organizationId}/teams/{teamId}` | Rename external team (header mode only) | apps/server/src/client/App.tsx |
| deleteTeam | maintained | DELETE `/api/v1/organizations/{organizationId}/teams/{teamId}` | `/api/v1/organizations/{organizationId}/teams/{teamId}` | Delete external team (header mode only) | apps/server/src/client/App.tsx |
| listTeamMembers | modified | GET `/api/v1/organizations/{organizationId}/teams/{teamId}/members` | `/api/v1/organizations/{organizationId}/teams/{teamId}/members` | External team members (header mode only) | apps/server/src/client/App.tsx |
| putTeamMember | maintained | PUT `/api/v1/organizations/{organizationId}/teams/{teamId}/members/{userId}` | `/api/v1/organizations/{organizationId}/teams/{teamId}/members/{userId}` | Add an organization member to an external team | apps/server/src/client/App.tsx |
| deleteTeamMember | maintained | DELETE `/api/v1/organizations/{organizationId}/teams/{teamId}/members/{userId}` | `/api/v1/organizations/{organizationId}/teams/{teamId}/members/{userId}` | Remove an external team member | apps/server/src/client/App.tsx |

## Delegated protocols

These concrete endpoints preserve Better Auth/OAuth/OIDC, OpenAI and MCP formats. Dahlia Problem/DTO conventions do not apply. OAuth client and resource management are registered by the provider but denied by denyOAuthManagement; dynamic client registration is disabled. Email/password sign-in is not enabled. Plugin/session/organization/admin checks remain authoritative. The installed provider inventory is tested; it is not represented by a wildcard claim of OpenAPI coverage.

| Operation | Method / path | Protocol | Availability |
| --- | --- | --- | --- |
| getOAuthServerConfig | GET `/api/auth/.well-known/oauth-authorization-server` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getOpenIdConfig | GET `/api/auth/.well-known/openid-configuration` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| accountInfo | GET `/api/auth/account-info` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| banUser | POST `/api/auth/admin/ban-user` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| createUser | POST `/api/auth/admin/create-user` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getUser | GET `/api/auth/admin/get-user` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| userHasPermission | POST `/api/auth/admin/has-permission` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| impersonateUser | POST `/api/auth/admin/impersonate-user` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listUserSessions | POST `/api/auth/admin/list-user-sessions` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listUsers | GET `/api/auth/admin/list-users` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminCreateOAuthClient | POST `/api/auth/admin/oauth2/create-client` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminListOAuthResources | GET `/api/auth/admin/oauth2/resources` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminCreateOAuthResource | POST `/api/auth/admin/oauth2/resources` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminDeleteOAuthResource | DELETE `/api/auth/admin/oauth2/resources/:identifier` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminGetOAuthResource | GET `/api/auth/admin/oauth2/resources/:identifier` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminUpdateOAuthResource | PATCH `/api/auth/admin/oauth2/resources/:identifier` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminUnlinkClientResource | DELETE `/api/auth/admin/oauth2/resources/:identifier/clients/:client_id` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminLinkClientResource | POST `/api/auth/admin/oauth2/resources/:identifier/clients/:client_id` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminUpdateOAuthClient | PATCH `/api/auth/admin/oauth2/update-client` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| removeUser | POST `/api/auth/admin/remove-user` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| revokeUserSession | POST `/api/auth/admin/revoke-user-session` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| revokeUserSessions | POST `/api/auth/admin/revoke-user-sessions` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| setRole | POST `/api/auth/admin/set-role` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| setUserPassword | POST `/api/auth/admin/set-user-password` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| stopImpersonating | POST `/api/auth/admin/stop-impersonating` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| unbanUser | POST `/api/auth/admin/unban-user` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| adminUpdateUser | POST `/api/auth/admin/update-user` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| callbackOAuth | GET `/api/auth/callback/:id` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| callbackOAuth | POST `/api/auth/callback/:id` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| changeEmail | POST `/api/auth/change-email` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| changePassword | POST `/api/auth/change-password` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| deleteUser | POST `/api/auth/delete-user` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| deleteUserCallback | GET `/api/auth/delete-user/callback` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| error | GET `/api/auth/error` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getAccessToken | POST `/api/auth/get-access-token` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getSession | GET `/api/auth/get-session` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getSession | POST `/api/auth/get-session` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getJwks | GET `/api/auth/jwks` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| linkSocialAccount | POST `/api/auth/link-social` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listUserAccounts | GET `/api/auth/list-accounts` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listSessions | GET `/api/auth/list-sessions` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2Authorize | GET `/api/auth/oauth2/authorize` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2Authorize | POST `/api/auth/oauth2/authorize` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| rotateClientSecret | POST `/api/auth/oauth2/client/rotate-secret` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2Consent | POST `/api/auth/oauth2/consent` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2Continue | POST `/api/auth/oauth2/continue` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| createOAuthClient | POST `/api/auth/oauth2/create-client` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| deleteOAuthClient | POST `/api/auth/oauth2/delete-client` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| deleteOAuthConsent | POST `/api/auth/oauth2/delete-consent` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2EndSession | GET `/api/auth/oauth2/end-session` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2EndSession | POST `/api/auth/oauth2/end-session` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2EndSessionConfirmation | POST `/api/auth/oauth2/end-session/confirm` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getOAuthClient | GET `/api/auth/oauth2/get-client` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getOAuthClients | GET `/api/auth/oauth2/get-clients` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getOAuthConsent | GET `/api/auth/oauth2/get-consent` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getOAuthConsents | GET `/api/auth/oauth2/get-consents` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2Introspect | POST `/api/auth/oauth2/introspect` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getOAuthClientPublic | GET `/api/auth/oauth2/public-client` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getOAuthClientPublicPrelogin | POST `/api/auth/oauth2/public-client-prelogin` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| registerOAuthClient | POST `/api/auth/oauth2/register` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2Revoke | POST `/api/auth/oauth2/revoke` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2Token | POST `/api/auth/oauth2/token` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| updateOAuthClient | POST `/api/auth/oauth2/update-client` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| updateOAuthConsent | POST `/api/auth/oauth2/update-consent` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2UserInfo | GET `/api/auth/oauth2/userinfo` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauth2UserInfo | POST `/api/auth/oauth2/userinfo` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| ok | GET `/api/auth/ok` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| acceptInvitation | POST `/api/auth/organization/accept-invitation` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| addTeamMember | POST `/api/auth/organization/add-team-member` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| cancelInvitation | POST `/api/auth/organization/cancel-invitation` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| checkOrganizationSlug | POST `/api/auth/organization/check-slug` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| createOrganization | POST `/api/auth/organization/create` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| createTeam | POST `/api/auth/organization/create-team` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| deleteOrganization | POST `/api/auth/organization/delete` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getActiveMember | GET `/api/auth/organization/get-active-member` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getActiveMemberRole | GET `/api/auth/organization/get-active-member-role` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getFullOrganization | GET `/api/auth/organization/get-full-organization` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getInvitation | GET `/api/auth/organization/get-invitation` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getOrganization | GET `/api/auth/organization/get-organization` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| hasPermission | POST `/api/auth/organization/has-permission` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| createInvitation | POST `/api/auth/organization/invite-member` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| leaveOrganization | POST `/api/auth/organization/leave` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listOrganizations | GET `/api/auth/organization/list` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listInvitations | GET `/api/auth/organization/list-invitations` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listMembers | GET `/api/auth/organization/list-members` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listTeamMembers | GET `/api/auth/organization/list-team-members` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listOrganizationTeams | GET `/api/auth/organization/list-teams` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listUserInvitations | GET `/api/auth/organization/list-user-invitations` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| listUserTeams | GET `/api/auth/organization/list-user-teams` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| rejectInvitation | POST `/api/auth/organization/reject-invitation` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| removeMember | POST `/api/auth/organization/remove-member` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| removeTeam | POST `/api/auth/organization/remove-team` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| removeTeamMember | POST `/api/auth/organization/remove-team-member` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| setActiveOrganization | POST `/api/auth/organization/set-active` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| setActiveTeam | POST `/api/auth/organization/set-active-team` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| updateOrganization | POST `/api/auth/organization/update` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| updateMemberRole | POST `/api/auth/organization/update-member-role` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| updateTeam | POST `/api/auth/organization/update-team` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| refreshToken | POST `/api/auth/refresh-token` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| requestPasswordReset | POST `/api/auth/request-password-reset` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| resetPassword | POST `/api/auth/reset-password` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| requestPasswordResetCallback | GET `/api/auth/reset-password/:token` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| revokeOtherSessions | POST `/api/auth/revoke-other-sessions` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| revokeSession | POST `/api/auth/revoke-session` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| revokeSessions | POST `/api/auth/revoke-sessions` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| sendVerificationEmail | POST `/api/auth/send-verification-email` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| signInEmail | POST `/api/auth/sign-in/email` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| signInSocial | POST `/api/auth/sign-in/social` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| signOut | POST `/api/auth/sign-out` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| signUpEmail | POST `/api/auth/sign-up/email` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| getToken | GET `/api/auth/token` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| unlinkAccount | POST `/api/auth/unlink-account` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| updateSession | POST `/api/auth/update-session` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| updateUser | POST `/api/auth/update-user` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| verifyEmail | GET `/api/auth/verify-email` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| verifyPassword | POST `/api/auth/verify-password` | Better Auth / OAuth / OIDC | accounts; plugin privileges and session roles still apply |
| oauthServerMetadata | GET `/.well-known/oauth-authorization-server` | RFC 8414 | accounts |
| openidMetadata | GET `/.well-known/openid-configuration` | OIDC discovery | accounts |
| gatewayResourceMetadata | GET `/.well-known/oauth-protected-resource` | RFC 9728 | accounts |
| mcpResourceMetadata | GET `/.well-known/oauth-protected-resource/mcp` | RFC 9728 | accounts |
| listModels | GET `/api/v1/models` | OpenAI / Codex model catalog | configured AI backend; all-apis or trusted proxy |
| createResponse | POST `/api/v1/responses` | OpenAI Responses / SSE | configured AI backend; all-apis or trusted proxy |
| mcp | POST `/mcp` | MCP 2026-07-28 stateless JSON-RPC | MCP OAuth scopes/DPoP or trusted proxy |
| mcpScreenshot | GET `/mcp/resources/vaults/{vaultId}/meetings/{meetingId}/screenshots/{screenshotId}/content` | MCP resource HTTP bytes | current Vault read permission and MCP read scope |
| headMcpScreenshot | HEAD `/mcp/resources/vaults/{vaultId}/meetings/{meetingId}/screenshots/{screenshotId}/content` | MCP resource HTTP bytes | current Vault read permission and MCP read scope |

MCP methods: tools/list, tools/call. Tools: search, query_meetings, query_projects, get_project, get_meeting, get_meeting_transcript, query_screenshots, get_meeting_screenshots. Read-only. Each call checks its capability scope and current Vault access.

## Dispatch and fallbacks

- /.well-known/*: unknown metadata -> native 404
- /api/auth/*: dispatch only the concrete Better Auth endpoints listed here
- /mcp: unsupported methods -> 405 Allow: POST
- /api/*: unknown API -> Dahlia 404 inside v1; native 404 outside v1
- extension routes: deployment-owned, audited by the registering extension
