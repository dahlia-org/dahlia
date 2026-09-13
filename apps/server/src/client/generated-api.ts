export interface paths {
    "/healthz": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Process health */
        get: operations["getHealth"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/openapi.json": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Public OpenAPI 3.1 contract */
        get: operations["getOpenAPI"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/session": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Current browser identity */
        get: operations["getSession"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/sessions": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** OAuth sessions (accounts mode only) */
        get: operations["listSessions"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/sessions/{id}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post?: never;
        /** Revoke an OAuth session */
        delete: operations["revokeSession"];
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/admin/members": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** List platform administrators; administrator only */
        get: operations["listAdministrators"];
        put?: never;
        /** Grant administrator access to an existing user */
        post: operations["addAdministrator"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/admin/search-settings": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Read server-wide full-text search weights; administrator only */
        get: operations["getSearchSettings"];
        /** Replace all six search weights (integers 1–10); applies to subsequent searches */
        put: operations["updateSearchSettings"];
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/admin/members/{userId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post?: never;
        /** Revoke administrator access; retain the last administrator */
        delete: operations["removeAdministrator"];
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/admin/users": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Administrator directory; ordered by name and ID */
        get: operations["listServerUsers"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/admin/organizations": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Administrator organization directory */
        get: operations["listServerOrganizations"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/admin/organizations/{organizationId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Organization directory details; administrator only, independent of membership */
        get: operations["getServerOrganization"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/account/settings": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Read current account settings */
        get: operations["getSettings"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        /** Merge supplied fields, including nested summary settings; maximum 8 KiB */
        patch: operations["updateSettings"];
        trace?: never;
    };
    "/api/v1/capabilities": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Discover feature versions; unsupported features are omitted */
        get: operations["getCapabilities"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Accessible Workspaces */
        get: operations["listWorkspaces"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Get Workspace */
        get: operations["getWorkspace"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/projects": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Workspace project tree */
        get: operations["listProjects"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/projects/{projectId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Resolve and get an accessible Project */
        get: operations["getProject"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/meetings": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Meetings by creation time and ID; 200 per page */
        get: operations["listMeetings"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Resolve and get meeting metadata */
        get: operations["getMeeting"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/summaries": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Summary versions, newest first; bodies omitted */
        get: operations["listSummaries"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/summaries/{version}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Read a saved summary version */
        get: operations["getSummary"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/summaries/latest": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Current summary; present=false when absent */
        get: operations["getLatestSummary"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/transcripts": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Transcript versions, newest first */
        get: operations["listTranscripts"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/transcripts/{version}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Read a transcript version in bounded pages */
        get: operations["getTranscript"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/transcripts/latest": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Read current transcript; match version and syncRevision across pages */
        get: operations["getLatestTranscript"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/transcripts/{version}/conversation-analytics": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Calculate owner-only conversation analytics for one immutable transcript version */
        get: operations["getConversationAnalytics"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/summary-jobs": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** Queue an owner-only summary job; ID is the replay key; maximum 8 KiB */
        post: operations["startSummaryJob"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/summary-jobs/latest": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Most recent owner-visible job, or null */
        get: operations["getLatestSummaryJob"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/summary-jobs/{jobId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Get an individual owner-visible job */
        get: operations["getSummaryJob"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/summary-jobs/{jobId}/cancel": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** Cancel a job; repeated cancellation is safe */
        post: operations["cancelSummaryJob"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/summary-jobs/{jobId}/retry": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** Retry a failed or cancelled job using a new ID */
        post: operations["retrySummaryJob"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/transactions": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** Commit one atomic Workspace transaction; maximum 8 MiB */
        post: operations["commitTransaction"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/transactions/resolve": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** Resolve the exact original request without mutating; never advance the pull cursor from receipts */
        post: operations["resolveTransaction"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/changes": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Durable delta feed; retain highWaterCursor across a catch-up */
        get: operations["getChanges"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/snapshot": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Bounded snapshot; retain startCursor and catch up before reconciliation */
        get: operations["getSnapshot"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/search": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** Ranked search with explicit truncation indicators; maximum 16 KiB */
        post: operations["search"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/text-search": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** Exhaustive full-text search pages; cursor invalidates when the ledger changes */
        post: operations["textSearch"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/events": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** SSE invalidation and account_settings events; recover through canonical reads */
        get: operations["getEvents"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/transcript-uploads/{patchId}/chunks/{chunkIndex}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        /** Stage an owner-only transcript patch chunk; SHA-256 of exact request bytes */
        put: operations["putTranscriptChunk"];
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/file-uploads": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** Reserve private file staging with a client-generated UUIDv7; maximum 8 KiB */
        post: operations["reserveFileUpload"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/file-uploads/{fileId}/content": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        /** Stream reserved file bytes; identical replay succeeds, different content conflicts */
        put: operations["putFileContent"];
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/files/{fileId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** File JSON metadata; staged files are owner-only */
        get: operations["getFile"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        /** Owner metadata patch with baseRevision; maximum 128 KiB */
        patch: operations["updateFile"];
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/files": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Committed files by ID; 200 per page */
        get: operations["listFiles"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/files": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Meeting file links by ID; 200 per page */
        get: operations["listMeetingFiles"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/files/{fileId}/content": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Stream original file */
        get: operations["getFileContent"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        /** File headers; Range ignored; no body */
        head: operations["headFileContent"];
        patch?: never;
        trace?: never;
    };
    "/api/v1/files/{fileId}/variants/{variant}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Stream image variant */
        get: operations["getFileVariant"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        /** Variant headers; Range ignored; no body */
        head: operations["headFileVariant"];
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/recording-uploads/{sessionId}/audio/{source}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        /** Stage audio/mp4; maximum 1 GiB; Transaction activates the recording */
        put: operations["putRecordingContent"];
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/recordings": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Committed recordings by meeting-local number; 200 per page */
        get: operations["listRecordings"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/meetings/{meetingId}/recordings/{recordingId}/audio/{source}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Stream recording audio */
        get: operations["getRecordingContent"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        /** Recording headers; Range ignored; no body */
        head: operations["headRecordingContent"];
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/transfer-audience": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Preview readers gaining or losing access; admin only */
        get: operations["getTransferAudience"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/transfer": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** Move all content after revision and audience checks; admin only */
        post: operations["transferWorkspace"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/relocations": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Resolve moved resources to currently accessible Workspaces */
        get: operations["getRelocations"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/permission-targets": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Search own organizations, their teams and co-members; admin only; 50 per type per page */
        get: operations["searchPermissionTargets"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/permissions/users/{userId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        /** Grant access to a known user; admin only */
        put: operations["putUserPermission"];
        post?: never;
        /** Revoke direct user access; admin only */
        delete: operations["deleteUserPermission"];
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/permissions": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Read Workspace sharing permissions */
        get: operations["listPermissions"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/permissions/organizations/{organizationId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        /** Grant organization access; admin only */
        put: operations["putOrganizationPermission"];
        post?: never;
        /** Revoke organization access; admin only */
        delete: operations["deleteOrganizationPermission"];
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/workspaces/{workspaceId}/permissions/teams/{teamId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        /** Grant team access; admin only */
        put: operations["putTeamPermission"];
        post?: never;
        /** Revoke team access; admin only */
        delete: operations["deleteTeamPermission"];
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/organizations/{organizationId}/workspaces": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Organization Workspace metadata; organization owner or admin only */
        get: operations["listGovernanceWorkspaces"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/organizations/{organizationId}/workspaces/{workspaceId}/deletion": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Confirm the current Workspace revision and content cursor */
        get: operations["confirmWorkspaceDeletion"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/organizations/{organizationId}/workspaces/{workspaceId}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post?: never;
        /** Delete a Team Organization Workspace after confirmation */
        delete: operations["forceDeleteWorkspace"];
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/api/v1/organizations": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        /** Current organization memberships */
        get: operations["listOrganizations"];
        put?: never;
        /** Create a Team Organization and creator membership through Better Auth */
        post: operations["createOrganization"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
}
export type webhooks = Record<string, never>;
export interface components {
    schemas: {
        Workspace: {
            /** @enum {string} */
            encryption?: "none" | "server";
            workspaceId: string;
            organizationId: string;
            name: string;
            icon?: string | null;
            color?: string | null;
            active?: boolean;
            /** Format: date-time */
            deletingAt?: string | null;
            revision: number;
            /** Format: date-time */
            createdAt: string;
            /** Format: date-time */
            updatedAt: string;
            /** @enum {string} */
            role: "admin" | "editor" | "viewer";
            hasResources?: boolean;
        };
        Project: {
            projectId: string;
            workspaceId: string;
            parentProjectId: string | null;
            name: string;
            description: string;
            /** @enum {string|null} */
            projectType: "customer" | "internal" | "personal" | "undefined" | null;
            icon?: string | null;
            color?: string | null;
            active?: boolean;
            /** Format: date-time */
            deletingAt?: string | null;
            revision: number;
            /** Format: date-time */
            createdAt: string;
            path?: string;
            rootProjectId?: string;
            effectiveType?: string;
            typeOwnerProjectId?: string;
            directMeetingCount?: number;
            subtreeMeetingCount?: number;
        };
        Meeting: {
            meetingId: string;
            workspaceId: string;
            projectId: string | null;
            name: string;
            description: string;
            /** @enum {string} */
            status: "PROCESSING_TRANSCRIPT" | "TRANSCRIPT_NOT_FOUND" | "READY" | "RECORDING";
            duration: number | null;
            /** Format: date-time */
            recordingStartedAt: string | null;
            isRecording?: boolean;
            icalUid: string | null;
            recurrenceId: string | null;
            calendarEvent: {
                /** Format: date-time */
                start: string;
                /** Format: date-time */
                end: string;
                is_all_day: boolean;
                attendees?: {
                    /** Format: email */
                    email: string;
                    display_name: string | null;
                }[];
            } | null;
            /** Format: date-time */
            createdAt: string;
            /** Format: date-time */
            updatedAt: string;
            active?: boolean;
            /** Format: date-time */
            deletingAt?: string | null;
            revision: number;
            contentOmitted?: boolean;
            contentPresent?: boolean;
            hasSummary?: boolean;
            summaryRevision?: number;
            transcriptRevision?: number;
        };
        File: {
            id: string;
            workspaceId: string;
            name: string;
            contentType: string;
            size: number;
            checksum: string;
            metadata: components["schemas"]["FileMetadata"];
            revision: number;
            /** Format: date-time */
            createdAt: string;
            /** Format: date-time */
            updatedAt: string;
            active?: boolean;
            contentUrl?: string;
            variants?: {
                [key: string]: string;
            };
            contentOmitted?: boolean;
            contentPresent?: boolean;
        };
        FileMetadata: {
            /** @enum {string} */
            source: "upload" | "screenshot";
            width?: number;
            height?: number;
            caption?: string | null;
            ocrText?: string | null;
        };
        Transcript: {
            id: string;
            meetingId: string;
            version: number;
            syncRevision: number;
            /** @enum {string} */
            status: "active" | "inactive" | "ended" | "unknown";
            /** Format: date-time */
            startedAt: string | null;
            /** Format: date-time */
            endedAt: string | null;
            /** Format: date-time */
            latestSegmentCreatedAt: string | null;
            /** Format: date-time */
            createdAt: string;
            metadata: components["schemas"]["NullableTranscriptMetadata"];
        };
        NullableTranscriptMetadata: {
            provider: string;
            request: {
                model: string;
            };
            runs: {
                /** @enum {string} */
                generatedBy: "desktop" | "server";
                inputTypes: "audio"[];
                /** Format: date-time */
                startedAt?: string | null;
                /** Format: date-time */
                completedAt?: string | null;
                language?: {
                    /** @enum {string} */
                    mode: "auto" | "fixed";
                    locales: string[];
                };
                recognitionLocales?: string[];
                response?: components["schemas"]["SummaryResponseMetadata"];
                recordingSessionId?: string;
                audioInputs?: {
                    recordingNumber: number;
                    /** @enum {string} */
                    source: "mic" | "system";
                    checksum: string;
                }[];
            }[];
        } | null;
        SummaryResponseMetadata: {
            id?: string | null;
            model?: string | null;
            created_at?: number | null;
            reasoning?: {
                effort?: string | null;
                summary?: string | null;
            } | null;
            usage?: {
                input_tokens?: number | null;
                output_tokens?: number | null;
                total_tokens?: number | null;
                input_tokens_details?: {
                    cached_tokens?: number | null;
                } | null;
                output_tokens_details?: {
                    reasoning_tokens?: number | null;
                } | null;
            } | null;
        };
        Summary: {
            id: string;
            meetingId: string;
            version: number;
            title: string;
            document: string;
            /** Format: date-time */
            createdAt: string | null;
            /** Format: date-time */
            savedAt: string;
            metadata: components["schemas"]["NullableSummaryMetadata"];
        };
        NullableSummaryMetadata: {
            /** @enum {string} */
            generatedBy: "server" | "local_codex";
            inputTypes: ("transcript" | "image" | "audio" | "note" | "context")[];
            detailLevel?: string | null;
            outputLanguage?: string | null;
            request: {
                model?: string | null;
                reasoning?: {
                    effort?: string | null;
                    summary?: string | null;
                };
            };
            response?: components["schemas"]["SummaryResponseMetadata"];
        } | null;
        Recording: {
            id: number;
            /** Format: date-time */
            startedAt: string;
            /** Format: date-time */
            endedAt: string;
            audio: {
                mic?: components["schemas"]["RecordingAudio"];
                system?: components["schemas"]["RecordingAudio"];
            };
        };
        RecordingAudio: {
            fileId?: string;
            /** @enum {string} */
            contentType: "audio/mp4";
            size: number;
            checksum: string | null;
            contentUrl: string;
            manifest?: {
                /** @enum {number} */
                sampleRate: 16000;
                frameCount: number;
                ranges: {
                    startFrame: number;
                    frameCount: number;
                    sessionOffsetSeconds: number;
                    localeIdentifier: string;
                }[];
            };
        };
        FileWriteMetadata: {
            /** @enum {string} */
            source: "upload" | "screenshot";
            width?: number;
            height?: number;
            caption?: string | null;
            ocrText?: string | null;
        };
        CurrentSession: {
            capabilities: {
                admin: boolean;
                sessions: boolean;
                sync: boolean;
                sharing: boolean;
            } & {
                [key: string]: boolean;
            };
            user: {
                id: string;
                name?: string;
                email?: string;
            };
        };
        /** @description RFC 9457 problem details. Branch on code, not the human-readable title. */
        Problem: {
            type: string;
            title: string;
            status: number;
            code: string;
            detail?: string;
            conflicts?: components["schemas"]["RevisionConflict"][];
            operationId?: string;
        };
        RevisionConflict: {
            /** @enum {string} */
            entity: "workspace";
            id: string;
            clientBaseRevision: number | null;
            serverRevision: number | null;
            record: components["schemas"]["NullableWorkspaceRecord"];
        } | {
            /** @enum {string} */
            entity: "project";
            id: string;
            clientBaseRevision: number | null;
            serverRevision: number | null;
            record: components["schemas"]["NullableProjectRecord"];
        } | {
            /** @enum {string} */
            entity: "meeting";
            id: string;
            clientBaseRevision: number | null;
            serverRevision: number | null;
            record: components["schemas"]["NullableMeetingRecord"];
        } | {
            /** @enum {string} */
            entity: "summary";
            id: string;
            clientBaseRevision: number | null;
            serverRevision: number | null;
            record: components["schemas"]["NullableSummaryRecord"];
        } | {
            /** @enum {string} */
            entity: "transcript";
            id: string;
            clientBaseRevision: number | null;
            serverRevision: number | null;
            record: components["schemas"]["NullableTranscriptRecord"];
        } | {
            /** @enum {string} */
            entity: "file";
            id: string;
            clientBaseRevision: number | null;
            serverRevision: number | null;
            record: components["schemas"]["NullableFileRecord"];
        } | {
            /** @enum {string} */
            entity: "meeting_attachment";
            id: string;
            clientBaseRevision: number | null;
            serverRevision: number | null;
            record: components["schemas"]["NullableMeetingAttachmentRecord"];
        } | {
            /** @enum {string} */
            entity: "recording";
            id: string;
            clientBaseRevision: number | null;
            serverRevision: number | null;
            record: components["schemas"]["NullableRecordingRecord"];
        } | {
            /** @enum {string} */
            entity: "meeting_event";
            id: string;
            clientBaseRevision: number | null;
            serverRevision: number | null;
            record: components["schemas"]["NullableMeetingEventRecord"];
        };
        NullableWorkspaceRecord: {
            /** @enum {string} */
            encryption?: "none" | "server";
            workspaceId: string;
            organizationId: string;
            name: string;
            icon?: string | null;
            color?: string | null;
            active?: boolean;
            /** Format: date-time */
            deletingAt?: string | null;
            revision: number;
            /** Format: date-time */
            createdAt: string;
            /** Format: date-time */
            updatedAt: string;
            /** @enum {string} */
            role: "admin" | "editor" | "viewer";
            hasResources?: boolean;
        } | null;
        NullableProjectRecord: {
            projectId: string;
            workspaceId: string;
            parentProjectId: string | null;
            name: string;
            description: string;
            /** @enum {string|null} */
            projectType: "customer" | "internal" | "personal" | "undefined" | null;
            icon?: string | null;
            color?: string | null;
            active?: boolean;
            /** Format: date-time */
            deletingAt?: string | null;
            revision: number;
            /** Format: date-time */
            createdAt: string;
            path?: string;
            rootProjectId?: string;
            effectiveType?: string;
            typeOwnerProjectId?: string;
            directMeetingCount?: number;
            subtreeMeetingCount?: number;
        } | null;
        NullableMeetingRecord: {
            meetingId: string;
            workspaceId: string;
            projectId: string | null;
            name: string;
            description: string;
            /** @enum {string} */
            status: "PROCESSING_TRANSCRIPT" | "TRANSCRIPT_NOT_FOUND" | "READY" | "RECORDING";
            duration: number | null;
            /** Format: date-time */
            recordingStartedAt: string | null;
            isRecording?: boolean;
            icalUid: string | null;
            recurrenceId: string | null;
            calendarEvent: {
                /** Format: date-time */
                start: string;
                /** Format: date-time */
                end: string;
                is_all_day: boolean;
                attendees?: {
                    /** Format: email */
                    email: string;
                    display_name: string | null;
                }[];
            } | null;
            /** Format: date-time */
            createdAt: string;
            /** Format: date-time */
            updatedAt: string;
            active?: boolean;
            /** Format: date-time */
            deletingAt?: string | null;
            revision: number;
            contentOmitted?: boolean;
            contentPresent?: boolean;
            hasSummary?: boolean;
            summaryRevision?: number;
            transcriptRevision?: number;
        } | null;
        NullableSummaryRecord: {
            id: string | null;
            meetingId: string;
            version: number | null;
            title: string | null;
            /** Format: date-time */
            createdAt: string | null;
            document?: string | null;
            contentOmitted?: boolean;
            contentPresent?: boolean;
        } | null;
        NullableTranscriptRecord: {
            meetingId: string;
            transcript: components["schemas"]["NullableTranscript"];
            contentCount?: number;
            contentOmitted?: boolean;
            contentPresent?: boolean;
        } | null;
        NullableTranscript: {
            id: string;
            meetingId: string;
            version: number;
            syncRevision: number;
            /** @enum {string} */
            status: "active" | "inactive" | "ended" | "unknown";
            /** Format: date-time */
            startedAt: string | null;
            /** Format: date-time */
            endedAt: string | null;
            /** Format: date-time */
            latestSegmentCreatedAt: string | null;
            /** Format: date-time */
            createdAt: string;
            metadata: components["schemas"]["NullableTranscriptMetadata"];
        } | null;
        NullableFileRecord: {
            id: string;
            workspaceId: string;
            name: string;
            contentType: string;
            size: number;
            checksum: string;
            metadata: components["schemas"]["FileMetadata"];
            revision: number;
            /** Format: date-time */
            createdAt: string;
            /** Format: date-time */
            updatedAt: string;
            active?: boolean;
            contentUrl?: string;
            variants?: {
                [key: string]: string;
            };
            contentOmitted?: boolean;
            contentPresent?: boolean;
        } | null;
        NullableMeetingAttachmentRecord: {
            id: string;
            workspaceId: string;
            meetingId: string;
            fileId: string;
            /** Format: date-time */
            capturedAt: string | null;
            sessionId: string | null;
            /** Format: date-time */
            createdAt: string;
            revision: number;
        } | null;
        NullableRecordingRecord: {
            id: number;
            /** Format: date-time */
            startedAt: string;
            /** Format: date-time */
            endedAt: string;
            audio: {
                mic?: components["schemas"]["RecordingAudio"];
                system?: components["schemas"]["RecordingAudio"];
            };
            recordingNumber: number;
            sessionId: string;
            meetingId: string;
            workspaceId: string;
            revision: number;
        } | null;
        NullableMeetingEventRecord: Record<string, never> | null;
        Session: {
            id: string;
            /** Format: date-time */
            createdAt: string;
            /** Format: date-time */
            expiresAt: string;
            userAgent: string | null;
            current: boolean;
        };
        Administrator: components["schemas"]["Person"] & {
            /** Format: date-time */
            createdAt: string;
            /** @enum {string} */
            role: "admin";
            removable: boolean;
        };
        Person: {
            id: string;
            name: string;
            email: string;
        };
        Organization: {
            id: string;
            name: string;
            slug: string;
            /** @enum {string} */
            kind: "personal" | "team";
            role?: string;
        };
        AccountSettingsResponse: {
            settings: {
                /** @enum {string} */
                outputLanguage: "ja" | "en" | "zh" | "ko" | "fr" | "de" | "es";
                processing: {
                    /** @enum {string} */
                    location: "local" | "remote";
                    remote: {
                        /** @enum {string} */
                        workflow: "transcribeThenSummarize" | "combined";
                        summaryModel?: string;
                        transcriptionModel?: string;
                        /** @enum {string} */
                        reasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
                    };
                };
                summary: {
                    /** @enum {string} */
                    style: "concise" | "standard" | "detailed" | "eventSummary" | "eventTimeline";
                };
                analysisLanguages: {
                    /** @enum {string} */
                    scope: "all" | "selected";
                    identifiers: string[];
                };
            } | null;
        };
        Capabilities: {
            workspaceEncryption?: {
                version: number;
            };
            sync?: {
                version: number;
            };
            workspaceTransfers?: {
                version: number;
            };
            recordingArchive?: {
                version: number;
            };
            meetingEvents?: {
                version: number;
            };
            search?: {
                version: number;
            };
            imageAnalysis?: {
                version: number;
            };
            conversationAnalytics?: {
                version: number;
            };
            meetingSummaryGeneration?: {
                version: number;
                sources: ("transcript" | "audio")[];
                completeRecordings?: boolean;
            };
        };
        SummaryContent: {
            /** @enum {number} */
            formatVersion: 1;
            version: number;
            entityId: string;
            present: boolean;
            count: number;
            byteCount: number;
            sha256: string;
            /** @description Opaque cursor. Pass back unchanged with the original filters. */
            nextCursor?: string | null;
            /** @enum {string} */
            entity: "summary";
            revision: number;
            record?: {
                id?: string;
                meetingId?: string;
                version?: number;
                title: string | null;
                document: string | null;
                /** Format: date-time */
                createdAt: string | null;
                /** Format: date-time */
                savedAt?: string;
                metadata?: components["schemas"]["NullableSummaryMetadata"];
            };
        };
        TranscriptContent: {
            /** @enum {number} */
            formatVersion: 1;
            version: number;
            entityId: string;
            present: boolean;
            count: number;
            byteCount: number;
            sha256: string;
            /** @description Opaque cursor. Pass back unchanged with the original filters. */
            nextCursor?: string | null;
            /** @enum {string} */
            entity: "transcript";
            syncRevision: number;
            transcript: components["schemas"]["NullableTranscript"];
            items?: components["schemas"]["TranscriptSegment"][];
        };
        TranscriptSegment: {
            segmentId: string;
            /** Format: date-time */
            startedAt: string;
            /** Format: date-time */
            endedAt: string | null;
            text: string;
            /** Format: date-time */
            createdAt: string | null;
            audioSource: string | null;
            speakerLabel: string | null;
        };
        ConversationAnalytics: {
            /** @enum {string} */
            status: "ready";
            transcriptId: string;
            transcriptVersion: number;
            /** @enum {number} */
            calculationVersion: 1;
            recordingDuration: number;
            unionSpeechDuration: number;
            overlapDuration: number;
            conversationOccupancyRatio: number | null;
            overlapRatio: number | null;
            speechMergeGap: number;
            monologueMergeGap: number;
            sources: {
                /** @enum {string} */
                source: "mic" | "system";
                speechDuration: number;
                normalizedCharacterCount: number;
                segmentCount: number;
                unmeasurableSegmentCount: number;
                charactersPerMinute: number | null;
                speechShare: number | null;
            }[];
            longestMonologue: {
                /** @enum {string} */
                source: "mic" | "system";
                start: number;
                end: number;
            } | null;
            paceBucketDuration: number;
            paceSamples: {
                /** @enum {string} */
                source: "mic" | "system";
                start: number;
                end: number;
                charactersPerMinute: number;
                seriesIndex: number;
            }[];
            timelineIntervals: {
                /** @enum {string} */
                source: "mic" | "system";
                start: number;
                end: number;
            }[];
            overlapIntervals: {
                start: number;
                end: number;
            }[];
            overlapCount: number;
            isTimelineCondensed: boolean;
        };
        ConversationAnalyticsUnavailable: {
            /** @enum {string} */
            status: "unavailable";
            transcriptId: string;
            transcriptVersion: number;
            /** @enum {string} */
            reason: "recording_audio_missing";
        };
        SummaryJob: {
            id: string;
            /** @enum {string} */
            method: "transcript" | "audio";
            input?: {
                /** @enum {string} */
                type: "transcript";
                version: string;
            } | {
                /** @enum {string} */
                type: "recording";
                recordings: {
                    micFileId: string | null;
                    systemFileId: string | null;
                }[];
                transcriptionModel?: string;
            };
            /** @enum {string|null} */
            stage?: "transcribing" | "summarizing" | "generating" | "saving" | null;
            transcriptResult?: {
                transcriptId: string;
                version: string;
            } | null;
            settings: {
                model: string;
                /** @enum {string} */
                reasoningEffort: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
                /** @enum {string} */
                detail: "low" | "medium" | "high" | "xhigh" | "max";
                /** @enum {string} */
                transcriptionReasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
            };
            outputLanguage: string;
            /** @enum {string} */
            status: "pending" | "processing" | "succeeded" | "failed" | "cancelled";
            attempts: number;
            /** Format: date-time */
            createdAt: string;
            error: string | null;
        };
        TransactionReceipt: {
            id: string;
            /** @enum {string} */
            status: "committed";
            /** @description Opaque cursor. Pass back unchanged with the original filters. */
            cursor: string;
            /** @enum {string} */
            receipt?: "full" | "compact";
            records: components["schemas"]["CanonicalRecord"][];
        };
        CanonicalRecord: {
            /** @enum {string} */
            entity: "workspace";
            id: string;
            revision: number | null;
            record?: components["schemas"]["NullableWorkspaceRecord"];
        } | {
            /** @enum {string} */
            entity: "project";
            id: string;
            revision: number | null;
            record?: components["schemas"]["NullableProjectRecord"];
        } | {
            /** @enum {string} */
            entity: "meeting";
            id: string;
            revision: number | null;
            record?: components["schemas"]["NullableMeetingRecord"];
        } | {
            /** @enum {string} */
            entity: "summary";
            id: string;
            revision: number | null;
            record?: components["schemas"]["NullableSummaryRecord"];
        } | {
            /** @enum {string} */
            entity: "transcript";
            id: string;
            revision: number | null;
            record?: components["schemas"]["NullableTranscriptRecord"];
        } | {
            /** @enum {string} */
            entity: "file";
            id: string;
            revision: number | null;
            record?: components["schemas"]["NullableFileRecord"];
        } | {
            /** @enum {string} */
            entity: "meeting_attachment";
            id: string;
            revision: number | null;
            record?: components["schemas"]["NullableMeetingAttachmentRecord"];
        } | {
            /** @enum {string} */
            entity: "recording";
            id: string;
            revision: number | null;
            record?: components["schemas"]["NullableRecordingRecord"];
        } | {
            /** @enum {string} */
            entity: "meeting_event";
            id: string;
            revision: number | null;
            record?: components["schemas"]["NullableMeetingEventRecord"];
        };
        Transaction: {
            /** @enum {number} */
            schemaVersion: 3;
            id: string;
            workspaceId: string;
            /** Format: date-time */
            createdAt: string;
            operations: ({
                id: string;
                /** @enum {string} */
                entity: "meeting_event";
                /** @enum {string} */
                action: "create";
                entityId: string;
                baseRevision: number | null;
                data: {
                    meetingId: string;
                    /** @enum {string} */
                    kind: "tag_added" | "tag_removed";
                    /** Format: date-time */
                    occurredAt: string;
                    relatedId: string;
                } | {
                    meetingId: string;
                    /** @enum {string} */
                    kind: "recording_started" | "recording_ended";
                    /** Format: date-time */
                    occurredAt: string;
                    sessionId: string;
                } | {
                    meetingId: string;
                    /** @enum {string} */
                    kind: "segment_rotated";
                    /** Format: date-time */
                    occurredAt: string;
                    sessionId: string;
                    relatedId: string;
                    /** @enum {string} */
                    audioSource: "mic" | "system";
                    segmentIndex: number;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "workspace";
                /** @enum {string} */
                action: "create";
                entityId: string;
                baseRevision: number | null;
                data: {
                    organizationId: string;
                    /** @enum {string} */
                    encryption?: "none" | "server";
                    /** @enum {string|null} */
                    icon?: "workspace" | "folder" | "dollarsign.circle" | "book.closed" | "graduationcap" | "pencil" | "tag" | "curlybraces" | "terminal" | "music.note" | "popcorn" | "paintbrush" | "paintpalette" | "stethoscope" | "asterisk" | "camera.macro" | "briefcase" | "chart.bar" | "medal" | "dumbbell" | "notebook" | "scales" | "globe.desk" | "airplane" | "globe" | "wrench" | "pawprint" | "flask" | "brain" | "heart" | "pottedplant" | "film" | "cross.case" | "puzzlepiece" | "leaf" | null;
                    /** @enum {string|null} */
                    color?: "neutral" | "red" | "orange" | "yellow" | "green" | "blue" | "purple" | "pink" | null;
                    name: string;
                    /** Format: date-time */
                    createdAt: string;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "workspace";
                /** @enum {string} */
                action: "update";
                entityId: string;
                baseRevision: number | null;
                data: {
                    /** @enum {string} */
                    encryption?: "none" | "server";
                    /** @enum {string|null} */
                    icon?: "workspace" | "folder" | "dollarsign.circle" | "book.closed" | "graduationcap" | "pencil" | "tag" | "curlybraces" | "terminal" | "music.note" | "popcorn" | "paintbrush" | "paintpalette" | "stethoscope" | "asterisk" | "camera.macro" | "briefcase" | "chart.bar" | "medal" | "dumbbell" | "notebook" | "scales" | "globe.desk" | "airplane" | "globe" | "wrench" | "pawprint" | "flask" | "brain" | "heart" | "pottedplant" | "film" | "cross.case" | "puzzlepiece" | "leaf" | null;
                    /** @enum {string|null} */
                    color?: "neutral" | "red" | "orange" | "yellow" | "green" | "blue" | "purple" | "pink" | null;
                    name: string;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "workspace";
                /** @enum {string} */
                action: "reset";
                entityId: string;
                baseRevision: number | null;
                data: {
                    preservePermissions?: boolean;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "project";
                /** @enum {string} */
                action: "create";
                entityId: string;
                baseRevision: number | null;
                data: {
                    /** @enum {string|null} */
                    icon?: "workspace" | "folder" | "dollarsign.circle" | "book.closed" | "graduationcap" | "pencil" | "tag" | "curlybraces" | "terminal" | "music.note" | "popcorn" | "paintbrush" | "paintpalette" | "stethoscope" | "asterisk" | "camera.macro" | "briefcase" | "chart.bar" | "medal" | "dumbbell" | "notebook" | "scales" | "globe.desk" | "airplane" | "globe" | "wrench" | "pawprint" | "flask" | "brain" | "heart" | "pottedplant" | "film" | "cross.case" | "puzzlepiece" | "leaf" | null;
                    /** @enum {string|null} */
                    color?: "neutral" | "red" | "orange" | "yellow" | "green" | "blue" | "purple" | "pink" | null;
                    parentProjectId: string | null;
                    name: string;
                    /** @default  */
                    description: string;
                    /** @enum {string|null} */
                    projectType: "customer" | "internal" | "personal" | "undefined" | null;
                    /** Format: date-time */
                    createdAt: string;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "project";
                /** @enum {string} */
                action: "update";
                entityId: string;
                baseRevision: number | null;
                data: {
                    /** @enum {string|null} */
                    icon?: "workspace" | "folder" | "dollarsign.circle" | "book.closed" | "graduationcap" | "pencil" | "tag" | "curlybraces" | "terminal" | "music.note" | "popcorn" | "paintbrush" | "paintpalette" | "stethoscope" | "asterisk" | "camera.macro" | "briefcase" | "chart.bar" | "medal" | "dumbbell" | "notebook" | "scales" | "globe.desk" | "airplane" | "globe" | "wrench" | "pawprint" | "flask" | "brain" | "heart" | "pottedplant" | "film" | "cross.case" | "puzzlepiece" | "leaf" | null;
                    /** @enum {string|null} */
                    color?: "neutral" | "red" | "orange" | "yellow" | "green" | "blue" | "purple" | "pink" | null;
                    parentProjectId: string | null;
                    name: string;
                    /** @default  */
                    description: string;
                    /** @enum {string|null} */
                    projectType: "customer" | "internal" | "personal" | "undefined" | null;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "project";
                /** @enum {string} */
                action: "delete";
                entityId: string;
                baseRevision: number | null;
                data: Record<string, never>;
            } | {
                id: string;
                /** @enum {string} */
                entity: "meeting";
                /** @enum {string} */
                action: "create";
                entityId: string;
                baseRevision: number | null;
                data: {
                    calendarEvent?: {
                        /** Format: date-time */
                        start: string;
                        /** Format: date-time */
                        end: string;
                        is_all_day: boolean;
                        attendees?: {
                            /** Format: email */
                            email: string;
                            display_name: string | null;
                        }[];
                    } | null;
                    icalUid?: string | null;
                    recurrenceId?: string | null;
                    projectId: string | null;
                    name: string;
                    /** @default  */
                    description: string;
                    /** @enum {string} */
                    status: "TRANSCRIPT_NOT_FOUND" | "PROCESSING_TRANSCRIPT" | "READY" | "RECORDING";
                    duration: number | null;
                    /** Format: date-time */
                    recordingStartedAt: string | null;
                    /** Format: date-time */
                    createdAt: string;
                    /** Format: date-time */
                    updatedAt: string;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "meeting";
                /** @enum {string} */
                action: "update";
                entityId: string;
                baseRevision: number | null;
                data: {
                    calendarEvent?: {
                        /** Format: date-time */
                        start: string;
                        /** Format: date-time */
                        end: string;
                        is_all_day: boolean;
                        attendees?: {
                            /** Format: email */
                            email: string;
                            display_name: string | null;
                        }[];
                    } | null;
                    icalUid?: string | null;
                    recurrenceId?: string | null;
                    projectId: string | null;
                    name: string;
                    /** @default  */
                    description: string;
                    /** @enum {string} */
                    status: "TRANSCRIPT_NOT_FOUND" | "PROCESSING_TRANSCRIPT" | "READY" | "RECORDING";
                    duration: number | null;
                    /** Format: date-time */
                    recordingStartedAt: string | null;
                    /** Format: date-time */
                    updatedAt: string;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "meeting";
                /** @enum {string} */
                action: "delete";
                entityId: string;
                baseRevision: number | null;
                data: Record<string, never>;
            } | {
                id: string;
                /** @enum {string} */
                entity: "summary";
                /** @enum {string} */
                action: "upsert";
                entityId: string;
                baseRevision: number | null;
                data: {
                    title: string;
                    document: string;
                    /** Format: date-time */
                    createdAt: string;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "summary";
                /** @enum {string} */
                action: "delete";
                entityId: string;
                baseRevision: number | null;
                data: Record<string, never>;
            } | {
                id: string;
                /** @enum {string} */
                entity: "transcript";
                /** @enum {string} */
                action: "patch";
                entityId: string;
                baseRevision: number | null;
                data: {
                    transcript: {
                        id: string;
                        /** Format: date-time */
                        startedAt?: string | null;
                        /** Format: date-time */
                        endedAt?: string | null;
                        metadata?: {
                            provider: string;
                            request: {
                                model: string;
                            };
                            runs: {
                                /** @enum {string} */
                                generatedBy: "desktop" | "server";
                                inputTypes: "audio"[];
                                /** Format: date-time */
                                startedAt?: string | null;
                                /** Format: date-time */
                                completedAt?: string | null;
                                language?: {
                                    /** @enum {string} */
                                    mode: "auto" | "fixed";
                                    locales: string[];
                                };
                                recognitionLocales?: string[];
                                response?: components["schemas"]["SummaryResponseMetadata"];
                                recordingSessionId?: string;
                                audioInputs?: {
                                    recordingNumber: number;
                                    /** @enum {string} */
                                    source: "mic" | "system";
                                    checksum: string;
                                }[];
                            }[];
                        } | null;
                    };
                    /** @enum {string} */
                    mode: "replace" | "append";
                    patchId: string;
                    segmentCount: number;
                    deletionCount: number;
                    chunks: {
                        index: number;
                        sha256: string;
                        segmentCount: number;
                        deletionCount: number;
                    }[];
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "recording";
                /** @enum {string} */
                action: "upsert";
                entityId: string;
                baseRevision: number | null;
                data: {
                    /** @enum {string} */
                    source: "mic" | "system";
                    checksum: string;
                    manifest: {
                        /** @enum {number} */
                        sampleRate: 16000;
                        frameCount: number;
                        ranges: {
                            startFrame: number;
                            frameCount: number;
                            sessionOffsetSeconds: number;
                            localeIdentifier: string;
                        }[];
                    };
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "file";
                /** @enum {string} */
                action: "upsert";
                entityId: string;
                baseRevision: number | null;
                data: {
                    name?: string;
                    checksum: string;
                    metadata: {
                        /** @enum {string} */
                        source?: "upload" | "screenshot";
                        width?: number;
                        height?: number;
                        caption?: string | null;
                        ocrText?: string | null;
                    };
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "file";
                /** @enum {string} */
                action: "delete";
                entityId: string;
                baseRevision: number | null;
                data: Record<string, never>;
            } | {
                id: string;
                /** @enum {string} */
                entity: "meeting_attachment";
                /** @enum {string} */
                action: "upsert";
                entityId: string;
                baseRevision: number | null;
                data: {
                    meetingId: string;
                    fileId: string;
                    /** Format: date-time */
                    capturedAt: string | null;
                    sessionId: string | null;
                    /** Format: date-time */
                    createdAt: string;
                };
            } | {
                id: string;
                /** @enum {string} */
                entity: "meeting_attachment";
                /** @enum {string} */
                action: "delete";
                entityId: string;
                baseRevision: number | null;
                data: Record<string, never>;
            })[];
        };
        TransactionResolution: components["schemas"]["TransactionReceipt"] | {
            id: string;
            /** @enum {string} */
            status: "unknown";
        };
        Changes: {
            items: ({
                sequence: number;
                workspaceId: string;
                /** @enum {string} */
                entity: "workspace";
                entityId: string;
                /** @enum {string} */
                action: "upsert" | "delete" | "reset";
                revision: number | null;
                transactionId: string;
                record: components["schemas"]["NullableWorkspaceRecord"];
            } | {
                sequence: number;
                workspaceId: string;
                /** @enum {string} */
                entity: "project";
                entityId: string;
                /** @enum {string} */
                action: "upsert" | "delete" | "reset";
                revision: number | null;
                transactionId: string;
                record: components["schemas"]["NullableProjectRecord"];
            } | {
                sequence: number;
                workspaceId: string;
                /** @enum {string} */
                entity: "meeting";
                entityId: string;
                /** @enum {string} */
                action: "upsert" | "delete" | "reset";
                revision: number | null;
                transactionId: string;
                record: components["schemas"]["NullableMeetingRecord"];
            } | {
                sequence: number;
                workspaceId: string;
                /** @enum {string} */
                entity: "summary";
                entityId: string;
                /** @enum {string} */
                action: "upsert" | "delete" | "reset";
                revision: number | null;
                transactionId: string;
                record: components["schemas"]["NullableSummaryRecord"];
            } | {
                sequence: number;
                workspaceId: string;
                /** @enum {string} */
                entity: "transcript";
                entityId: string;
                /** @enum {string} */
                action: "upsert" | "delete" | "reset";
                revision: number | null;
                transactionId: string;
                record: components["schemas"]["NullableTranscriptRecord"];
            } | {
                sequence: number;
                workspaceId: string;
                /** @enum {string} */
                entity: "file";
                entityId: string;
                /** @enum {string} */
                action: "upsert" | "delete" | "reset";
                revision: number | null;
                transactionId: string;
                record: components["schemas"]["NullableFileRecord"];
            } | {
                sequence: number;
                workspaceId: string;
                /** @enum {string} */
                entity: "meeting_attachment";
                entityId: string;
                /** @enum {string} */
                action: "upsert" | "delete" | "reset";
                revision: number | null;
                transactionId: string;
                record: components["schemas"]["NullableMeetingAttachmentRecord"];
            } | {
                sequence: number;
                workspaceId: string;
                /** @enum {string} */
                entity: "recording";
                entityId: string;
                /** @enum {string} */
                action: "upsert" | "delete" | "reset";
                revision: number | null;
                transactionId: string;
                record: components["schemas"]["NullableRecordingRecord"];
            } | {
                sequence: number;
                workspaceId: string;
                /** @enum {string} */
                entity: "meeting_event";
                entityId: string;
                /** @enum {string} */
                action: "upsert" | "delete" | "reset";
                revision: number | null;
                transactionId: string;
                record: components["schemas"]["NullableMeetingEventRecord"];
            })[];
            /** @description Opaque cursor. Pass back unchanged with the original filters. */
            cursor: string;
            /** @description Opaque cursor. Pass back unchanged with the original filters. */
            highWaterCursor: string;
            hasMore: boolean;
        };
        Snapshot: {
            items: components["schemas"]["CanonicalRecord"][];
            /** @description Opaque cursor. Pass back unchanged with the original filters. */
            nextCursor: string | null;
            /** @description Opaque cursor. Pass back unchanged with the original filters. */
            startCursor: string;
        };
        SearchResults: {
            workspaceId: string;
            meetings: components["schemas"]["SearchHit"][];
            screenshots: components["schemas"]["SearchHit"][];
            projects: components["schemas"]["SearchHit"][];
            limited: {
                meeting: boolean;
                screenshot: boolean;
                project: boolean;
            };
        };
        SearchHit: {
            id: string;
            /** @enum {string} */
            kind: "meeting" | "screenshot" | "project";
            title: string;
            date: string;
            snippet: string;
            meetingId?: string;
            projectId?: string;
            projectPath?: string;
            fileId?: string;
            meetingCount?: number;
        };
        TextSearchResults: {
            items: {
                id: string;
                meetingId: string;
                snippet: string;
            }[];
            /** @description Opaque cursor. Pass back unchanged with the original filters. */
            nextCursor: string | null;
            /** @enum {number} */
            version: 1;
            /** @enum {string} */
            scope: "server";
        };
        TextSearchRequest: {
            query: string;
            /** @enum {string} */
            kind: "meeting" | "screenshot";
            /** @description Opaque cursor. Pass back unchanged with the original filters. */
            cursor?: string;
            limit?: number;
        };
        MeetingFile: {
            id: string;
            workspaceId: string;
            meetingId: string;
            fileId: string;
            /** Format: date-time */
            capturedAt: string | null;
            sessionId: string | null;
            /** Format: date-time */
            createdAt: string;
            revision: number;
        };
        RecordingUpload: {
            id: number;
            /** @enum {string} */
            source: "mic" | "system";
            /** @enum {string} */
            contentType: "audio/mp4";
            size: number;
            checksum: string;
            revision: number | null;
            contentUrl: string;
        };
        WorkspacePermission: {
            name?: string;
            detail?: string;
            workspaceId: string;
            /** @enum {string} */
            principalType: "user" | "organization" | "team";
            principalId: string;
            /** @enum {string} */
            role: "admin" | "editor" | "viewer";
            /** Format: date-time */
            createdAt: string;
        };
        GovernanceWorkspace: {
            workspaceId: string;
            name: string;
            revision: number;
            creatorId: string;
        };
    };
    responses: {
        /** @description Request failed. Use the HTTP status and Problem.code; 409 conflicts require reconciliation before retrying. */
        Problem: {
            headers: {
                "WWW-Authenticate"?: string;
                Allow?: string;
                "Retry-After"?: string;
                [name: string]: unknown;
            };
            content: {
                "application/problem+json": components["schemas"]["Problem"];
            };
        };
    };
    parameters: never;
    requestBodies: never;
    headers: never;
    pathItems: never;
}
export type $defs = Record<string, never>;
export interface operations {
    getHealth: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        status: "ok";
                    };
                };
            };
        };
    };
    getOpenAPI: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        openapi: "3.1.0";
                        info: {
                            title: string;
                            version: string;
                        } & {
                            [key: string]: unknown;
                        };
                        paths: {
                            [key: string]: unknown;
                        };
                    } & {
                        [key: string]: unknown;
                    };
                };
            };
        };
    };
    getSession: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["CurrentSession"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listSessions: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["Session"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    revokeSession: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                id: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Success; no response body. */
            204: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    listAdministrators: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["Administrator"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    addAdministrator: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /**
                     * Format: email
                     * @example person@example.com
                     */
                    email: string;
                };
            };
        };
        responses: {
            /** @description Created. An identical replay returns 200. */
            201: {
                headers: {
                    /** @description URI of the created representation or individual job. */
                    Location?: string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Administrator"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getSearchSettings: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        title: number;
                        tags: number;
                        description: number;
                        summary: number;
                        ocr: number;
                        caption: number;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    updateSearchSettings: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    title: number;
                    tags: number;
                    description: number;
                    summary: number;
                    ocr: number;
                    caption: number;
                };
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        title: number;
                        tags: number;
                        description: number;
                        summary: number;
                        ocr: number;
                        caption: number;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    removeAdministrator: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                userId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Success; no response body. */
            204: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    listServerUsers: {
        parameters: {
            query?: {
                /** @description 0–1000000. Fixed page size 100. */
                offset?: string;
            };
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: (components["schemas"]["Person"] & {
                            /** Format: date-time */
                            createdAt: string;
                            role: string | null;
                        })[];
                        hasMore: boolean;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listServerOrganizations: {
        parameters: {
            query?: {
                offset?: string;
            };
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: (components["schemas"]["Organization"] & {
                            memberCount: number;
                            teamCount: number;
                        })[];
                        hasMore: boolean;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getServerOrganization: {
        parameters: {
            query?: {
                membersOffset?: string;
                teamsOffset?: string;
            };
            header?: never;
            path: {
                organizationId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Organization"] & {
                        members: {
                            id: string;
                            userId: string;
                            role: string;
                            name: string;
                            email: string;
                        }[];
                        teams: {
                            id: string;
                            name: string;
                        }[];
                        hasMoreMembers: boolean;
                        hasMoreTeams: boolean;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getSettings: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["AccountSettingsResponse"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    updateSettings: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                /**
                 * @example {
                 *       "outputLanguage": "ja"
                 *     }
                 */
                "application/json": {
                    /** @enum {string} */
                    outputLanguage?: "ja" | "en" | "zh" | "ko" | "fr" | "de" | "es";
                    analysisLanguages?: {
                        /** @enum {string} */
                        scope: "all" | "selected";
                        identifiers: string[];
                    };
                    summary?: {
                        /** @enum {string} */
                        style?: "concise" | "standard" | "detailed" | "eventSummary" | "eventTimeline";
                    };
                    processing?: {
                        /** @enum {string} */
                        location?: "local" | "remote";
                        remote?: {
                            /** @enum {string} */
                            workflow?: "transcribeThenSummarize" | "combined";
                            summaryModel?: string | null;
                            transcriptionModel?: string | null;
                            /** @enum {string|null} */
                            reasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra" | null;
                        };
                    };
                    initialize?: boolean;
                };
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["AccountSettingsResponse"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getCapabilities: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Capabilities"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listWorkspaces: {
        parameters: {
            query?: {
                organizationId?: string;
            };
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["Workspace"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getWorkspace: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Workspace"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listProjects: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["Project"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getProject: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                projectId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Project"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listMeetings: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
                query?: string;
                projectId?: string;
                projectScope?: "direct" | "unassigned";
            };
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["Meeting"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getMeeting: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                meetingId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Meeting"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listSummaries: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
                /** @description 1–100; defaults to 20. */
                limit?: string;
            };
            header?: never;
            path: {
                meetingId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: {
                            id: string;
                            meetingId: string;
                            version: number;
                            title: string;
                            /** Format: date-time */
                            createdAt: string | null;
                            /** Format: date-time */
                            savedAt: string;
                            metadata: components["schemas"]["NullableSummaryMetadata"];
                        }[];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getSummary: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                meetingId: string;
                version: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Summary"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getLatestSummary: {
        parameters: {
            query?: {
                manifest?: "1";
            };
            header?: never;
            path: {
                meetingId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["SummaryContent"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listTranscripts: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
                /** @description 1–100; defaults to 20. */
                limit?: string;
            };
            header?: never;
            path: {
                meetingId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["Transcript"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getTranscript: {
        parameters: {
            query?: {
                manifest?: "1";
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
            };
            header?: never;
            path: {
                meetingId: string;
                version: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["TranscriptContent"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getLatestTranscript: {
        parameters: {
            query?: {
                manifest?: "1";
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
            };
            header?: never;
            path: {
                meetingId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["TranscriptContent"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getConversationAnalytics: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                meetingId: string;
                version: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["ConversationAnalytics"] | components["schemas"]["ConversationAnalyticsUnavailable"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    startSummaryJob: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                meetingId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    id: string;
                    input: {
                        /** @enum {string} */
                        type: "transcript";
                        version: string;
                    } | {
                        /** @enum {string} */
                        type: "recording";
                        recordings: {
                            micFileId: string | null;
                            systemFileId: string | null;
                        }[];
                        transcriptionModel?: string;
                    };
                    model: string;
                    /** @enum {string} */
                    detail: "low" | "medium" | "high" | "xhigh" | "max";
                    /** @enum {string} */
                    outputLanguage: "ja" | "en" | "zh" | "ko" | "fr" | "de" | "es";
                    /** @enum {string} */
                    reasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
                } | {
                    id: string;
                    /** @enum {string} */
                    detail?: "low" | "medium" | "high" | "xhigh" | "max";
                    /** @enum {string} */
                    outputLanguage?: "ja" | "en" | "zh" | "ko" | "fr" | "de" | "es";
                } | {
                    id: string;
                    input: {
                        /** @enum {string} */
                        type: "transcript";
                        version: string;
                    } | {
                        /** @enum {string} */
                        type: "recording";
                        recordings: {
                            micFileId: string | null;
                            systemFileId: string | null;
                        }[];
                    };
                    preferences: {
                        /** @enum {string} */
                        outputLanguage: "ja" | "en" | "zh" | "ko" | "fr" | "de" | "es";
                        processing: {
                            /** @enum {string} */
                            location: "local" | "remote";
                            remote: {
                                /** @enum {string} */
                                workflow: "transcribeThenSummarize" | "combined";
                                summaryModel?: string;
                                transcriptionModel?: string;
                                /** @enum {string} */
                                reasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
                            };
                        };
                        summary: {
                            /** @enum {string} */
                            style: "concise" | "standard" | "detailed" | "eventSummary" | "eventTimeline";
                        };
                    };
                };
            };
        };
        responses: {
            /** @description Accepted. Poll the individual job at Location. */
            202: {
                headers: {
                    /** @description URI of the created representation or individual job. */
                    Location?: string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        job: components["schemas"]["SummaryJob"];
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getLatestSummaryJob: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                meetingId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        job: {
                            id: string;
                            /** @enum {string} */
                            method: "transcript" | "audio";
                            input?: {
                                /** @enum {string} */
                                type: "transcript";
                                version: string;
                            } | {
                                /** @enum {string} */
                                type: "recording";
                                recordings: {
                                    micFileId: string | null;
                                    systemFileId: string | null;
                                }[];
                                transcriptionModel?: string;
                            };
                            /** @enum {string|null} */
                            stage?: "transcribing" | "summarizing" | "generating" | "saving" | null;
                            transcriptResult?: {
                                transcriptId: string;
                                version: string;
                            } | null;
                            settings: {
                                model: string;
                                /** @enum {string} */
                                reasoningEffort: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
                                /** @enum {string} */
                                detail: "low" | "medium" | "high" | "xhigh" | "max";
                                /** @enum {string} */
                                transcriptionReasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
                            };
                            outputLanguage: string;
                            /** @enum {string} */
                            status: "pending" | "processing" | "succeeded" | "failed" | "cancelled";
                            attempts: number;
                            /** Format: date-time */
                            createdAt: string;
                            error: string | null;
                        } | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getSummaryJob: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                meetingId: string;
                jobId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        job: components["schemas"]["SummaryJob"];
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    cancelSummaryJob: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                meetingId: string;
                jobId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        job: components["schemas"]["SummaryJob"];
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    retrySummaryJob: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                meetingId: string;
                jobId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    id: string;
                };
            };
        };
        responses: {
            /** @description Accepted. Poll the individual job at Location. */
            202: {
                headers: {
                    /** @description URI of the created representation or individual job. */
                    Location?: string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        job: components["schemas"]["SummaryJob"];
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    commitTransaction: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": components["schemas"]["Transaction"];
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["TransactionReceipt"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    resolveTransaction: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": components["schemas"]["Transaction"];
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["TransactionResolution"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getChanges: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                highWaterCursor?: string;
            };
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Changes"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getSnapshot: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                startCursor?: string;
            };
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Snapshot"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    search: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** @default  */
                    query?: string;
                    /** @enum {string} */
                    kind?: "meeting" | "screenshot" | "project";
                    projectId?: string;
                    /** Format: date-time */
                    from?: string;
                    /** Format: date-time */
                    to?: string;
                    /** @default 50 */
                    limit?: number;
                };
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["SearchResults"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    textSearch: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": components["schemas"]["TextSearchRequest"];
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["TextSearchResults"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getEvents: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
            };
            header?: {
                "last-event-id"?: string;
            };
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description text/event-stream: invalidation has {cursor}; account_settings has {}. No user content. */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "text/event-stream": string;
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    putTranscriptChunk: {
        parameters: {
            query?: never;
            header: {
                "x-dahlia-content-sha256": string;
            };
            path: {
                meetingId: string;
                patchId: string;
                chunkIndex: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    segments: {
                        segmentId: string;
                        /** Format: date-time */
                        startedAt: string;
                        /** Format: date-time */
                        endedAt: string | null;
                        text: string;
                        /** Format: date-time */
                        createdAt: string | null;
                        /** @enum {string|null} */
                        audioSource: "mic" | "system" | null;
                        speakerLabel: string | null;
                    }[];
                    deletions: string[];
                };
            };
        };
        responses: {
            /** @description Success; no response body. */
            204: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    reserveFileUpload: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    id: string;
                    workspaceId: string;
                    name: string;
                    contentType: string;
                    metadata: {
                        /** @enum {string} */
                        source: "upload" | "screenshot";
                        width?: number;
                        height?: number;
                    };
                };
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["File"];
                };
            };
            /** @description Created. An identical replay returns 200. */
            201: {
                headers: {
                    /** @description URI of the created representation or individual job. */
                    Location?: string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["File"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    putFileContent: {
        parameters: {
            query?: never;
            header: {
                "content-type": string;
                "content-length": string;
                "content-encoding"?: "identity";
            };
            path: {
                fileId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/octet-stream": string;
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["File"];
                };
            };
            /** @description Created. An identical replay returns 200. */
            201: {
                headers: {
                    /** @description URI of the created representation or individual job. */
                    Location?: string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["File"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getFile: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                fileId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["File"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    updateFile: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                fileId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    baseRevision: number;
                    metadata: {
                        width?: number;
                        height?: number;
                        caption?: string | null;
                        ocrText?: string | null;
                    };
                };
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["File"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listFiles: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
            };
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["File"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listMeetingFiles: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
            };
            header?: never;
            path: {
                meetingId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: (components["schemas"]["MeetingFile"] & {
                            file: components["schemas"]["File"];
                        })[];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getFileContent: {
        parameters: {
            query?: never;
            header?: {
                range?: string;
                "if-match"?: string;
                "if-none-match"?: string;
                "if-range"?: string;
                "if-modified-since"?: string;
                "if-unmodified-since"?: string;
            };
            path: {
                fileId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Streamed bytes. Authorization is checked before conditional responses. */
            200: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content: {
                    "*/*": string;
                };
            };
            /** @description Streamed bytes. Authorization is checked before conditional responses. */
            206: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content: {
                    "*/*": string;
                };
            };
            /** @description Not modified; no body. */
            304: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    headFileContent: {
        parameters: {
            query?: never;
            header?: {
                range?: string;
                "if-match"?: string;
                "if-none-match"?: string;
                "if-range"?: string;
                "if-modified-since"?: string;
                "if-unmodified-since"?: string;
            };
            path: {
                fileId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Full representation headers */
            200: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content?: never;
            };
            /** @description Success; no response body. */
            304: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    getFileVariant: {
        parameters: {
            query?: never;
            header?: {
                range?: string;
                "if-match"?: string;
                "if-none-match"?: string;
                "if-range"?: string;
                "if-modified-since"?: string;
                "if-unmodified-since"?: string;
            };
            path: {
                fileId: string;
                variant: "thumb_480" | "thumb_1280" | "thumb_1568" | "thumb_1920";
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Streamed bytes. Authorization is checked before conditional responses. */
            200: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content: {
                    "*/*": string;
                };
            };
            /** @description Streamed bytes. Authorization is checked before conditional responses. */
            206: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content: {
                    "*/*": string;
                };
            };
            /** @description Not modified; no body. */
            304: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    headFileVariant: {
        parameters: {
            query?: never;
            header?: {
                range?: string;
                "if-match"?: string;
                "if-none-match"?: string;
                "if-range"?: string;
                "if-modified-since"?: string;
                "if-unmodified-since"?: string;
            };
            path: {
                fileId: string;
                variant: "thumb_480" | "thumb_1280" | "thumb_1568" | "thumb_1920";
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Full representation headers */
            200: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content?: never;
            };
            /** @description Success; no response body. */
            304: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    putRecordingContent: {
        parameters: {
            query?: never;
            header: {
                "content-type": string;
                "content-length": string;
                "content-encoding"?: "identity";
            };
            path: {
                meetingId: string;
                sessionId: string;
                source: "mic" | "system";
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "audio/mp4": string;
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["RecordingUpload"];
                };
            };
            /** @description Created. An identical replay returns 200. */
            201: {
                headers: {
                    /** @description URI of the created representation or individual job. */
                    Location?: string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["RecordingUpload"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listRecordings: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
            };
            header?: never;
            path: {
                meetingId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["Recording"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getRecordingContent: {
        parameters: {
            query?: never;
            header?: {
                range?: string;
                "if-match"?: string;
                "if-none-match"?: string;
                "if-range"?: string;
                "if-modified-since"?: string;
                "if-unmodified-since"?: string;
            };
            path: {
                meetingId: string;
                recordingId: string;
                source: "mic" | "system";
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Streamed bytes. Authorization is checked before conditional responses. */
            200: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content: {
                    "audio/mp4": string;
                };
            };
            /** @description Streamed bytes. Authorization is checked before conditional responses. */
            206: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content: {
                    "audio/mp4": string;
                };
            };
            /** @description Not modified; no body. */
            304: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    headRecordingContent: {
        parameters: {
            query?: never;
            header?: {
                range?: string;
                "if-match"?: string;
                "if-none-match"?: string;
                "if-range"?: string;
                "if-modified-since"?: string;
                "if-unmodified-since"?: string;
            };
            path: {
                meetingId: string;
                recordingId: string;
                source: "mic" | "system";
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Full representation headers */
            200: {
                headers: {
                    "Content-Type"?: string;
                    "Content-Length"?: number;
                    "X-Dahlia-Image-Variant"?: string;
                    "X-Dahlia-Original-Sha256"?: string;
                    ETag?: string;
                    "Content-Range"?: string;
                    "Accept-Ranges"?: string;
                    "Cache-Control"?: string;
                    [name: string]: unknown;
                };
                content?: never;
            };
            /** @description Success; no response body. */
            304: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    getTransferAudience: {
        parameters: {
            query: {
                destinationWorkspaceId: string;
            };
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        audienceHash: string;
                        removed: components["schemas"]["Person"][];
                        added: components["schemas"]["Person"][];
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    transferWorkspace: {
        parameters: {
            query?: never;
            header: {
                "idempotency-key": string;
            };
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    destinationWorkspaceId: string;
                    sourceRevision: number;
                    destinationRevision: number;
                    audienceHash: string;
                };
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        id: string;
                        /** @enum {string} */
                        status: "committed";
                        sourceWorkspaceId: string;
                        destinationWorkspaceId: string;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    getRelocations: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        workspaces: components["schemas"]["Workspace"][];
                        items: {
                            /** @enum {string} */
                            entity: "project" | "meeting" | "file";
                            id: string;
                            workspaceId: string;
                        }[];
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    searchPermissionTargets: {
        parameters: {
            query?: {
                q?: string;
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
            };
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: {
                            /** @enum {string} */
                            principalType: "user" | "organization" | "team";
                            principalId: string;
                            name: string;
                            detail: string;
                        }[];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    putUserPermission: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
                userId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** @enum {string} */
                    role: "admin" | "editor" | "viewer";
                };
            };
        };
        responses: {
            /** @description Success; no response body. */
            204: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    deleteUserPermission: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
                userId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Success; no response body. */
            204: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    listPermissions: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["WorkspacePermission"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    putOrganizationPermission: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
                organizationId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** @enum {string} */
                    role: "admin" | "editor" | "viewer";
                };
            };
        };
        responses: {
            /** @description Success; no response body. */
            204: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    deleteOrganizationPermission: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
                organizationId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Success; no response body. */
            204: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    putTeamPermission: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
                teamId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** @enum {string} */
                    role: "admin" | "editor" | "viewer";
                };
            };
        };
        responses: {
            /** @description Success; no response body. */
            204: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    deleteTeamPermission: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                workspaceId: string;
                teamId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Success; no response body. */
            204: {
                headers: {
                    [name: string]: unknown;
                };
                content?: never;
            };
            default: components["responses"]["Problem"];
        };
    };
    listGovernanceWorkspaces: {
        parameters: {
            query?: {
                /** @description Opaque cursor. Pass back unchanged with the original filters. */
                cursor?: string;
            };
            header?: never;
            path: {
                organizationId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["GovernanceWorkspace"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    confirmWorkspaceDeletion: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                organizationId: string;
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["GovernanceWorkspace"] & {
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        changeCursor: string;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    forceDeleteWorkspace: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                organizationId: string;
                workspaceId: string;
            };
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    id: string;
                    revision: number;
                    /** @description Opaque cursor. Pass back unchanged with the original filters. */
                    changeCursor: string;
                };
            };
        };
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["TransactionReceipt"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    listOrganizations: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Successful response */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: components["schemas"]["Organization"][];
                        /** @description Opaque cursor. Pass back unchanged with the original filters. */
                        nextCursor: string | null;
                    };
                };
            };
            default: components["responses"]["Problem"];
        };
    };
    createOrganization: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    name: string;
                    slug: string;
                };
            };
        };
        responses: {
            /** @description Successful response */
            201: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Organization"];
                };
            };
            default: components["responses"]["Problem"];
        };
    };
}
