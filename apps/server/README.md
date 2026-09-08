# Dahlia Server

`apps/server` is the optional, self-hostable AI Gateway used by the Codex process embedded in Dahlia. It also accepts explicitly uploaded arbitrary-byte artifacts and provides the canonical shared data service for Dahlia Server accounts. Server Vaults and Projects are shared by Desktop and Private Web; Desktop SQLite is their offline working copy, not a one-way upload source. The service stores Vault names, Project names/descriptions/hierarchy, summaries, original transcripts, screenshots, OCR, and captions; it never stores recordings, translated transcripts, or SQLite databases. Responses request content is relayed to the configured provider without being persisted or logged.

Better Auth, Gateway administration, and meeting sync share one Drizzle application database. Provider credentials remain separate runtime secrets and are never stored in that database.

## Database and Gateway configuration

`DAHLIA_DATABASE_TYPE` selects storage independently from authentication and the AI Gateway:

| Type | Runtime | Connection |
| --- | --- | --- |
| `sqlite` | Node | `DAHLIA_DATABASE_URL=file:...` (default: `file:.data/dahlia-auth.sqlite`) |
| `postgres` | Node or Worker | `DAHLIA_DATABASE_URL=postgresql://...` |
| `lakebase` | Node / Databricks Apps | `LAKEBASE_ENDPOINT` and injected `PG*` variables |
| `hyperdrive` | Cloudflare Worker | `HYPERDRIVE` binding |
| `d1` | Cloudflare Worker | `dahlia_db_prod` binding |

Node supports `sqlite`, `postgres`, and `lakebase`; Workers support `d1`, `hyperdrive`, and direct `postgres`. PostgreSQL-compatible connections keep generated Better Auth tables in `auth`, all Dahlia-owned tables in `app`; all schemas are owned by the connection user. References flow from `app` to `auth`. Lakebase uses the official `@databricks/lakebase` pool for OAuth credential refresh.

The unreleased application baseline now uses `app` / unprefixed SQLite tables. Existing development databases using `core` / `content` require an explicit rebuild or separately planned data migration; rerunning migrations does not convert them.

Better Auth schemas are generated unmodified into `src/db/generated`; Dahlia tables remain in the adjacent app schema files. `pnpm db:generate-auth` refreshes the auth definitions and `pnpm db:generate` produces separate PostgreSQL auth and application streams under `drizzle/postgres-auth` and `drizzle/postgres`. Every authentication mode applies both streams in that order. Header mode keeps Better Auth endpoints disabled and projects each verified proxy identity into `auth.user`; accounts mode leaves that table under Better Auth's control. The relations-v2 adapter is used with joins disabled. SQLite and D1 retain one stream with top-level Better Auth tables, keep Dahlia table names unprefixed, and rely on the same application permission checks instead of RLS.

## API contract

| Path | `accounts` | `header` |
| --- | --- | --- |
| `/`, `/sign-in`, `/dashboard/**`, `/artifacts/**`, `/vaults/**` | Static SPA | Static SPA |
| `/organizations` | Better Auth Organization and Team management | External Organization and Team management |
| `/accept-invitation/**` | Better Auth invitation management | Not used |
| `/api/auth/**` | Google sign-in and OAuth 2.1 endpoints | Disabled |
| `/api/session` | Account session and capabilities | Validated email-header identity and capabilities |
| `/api/admin/**` | Platform administrators only | Platform administrators only |
| `/api/v1/models` | Dahlia OAuth with `all-apis` | Platform U2M / proxy authentication |
| `/api/v1/responses` | Dahlia OAuth with `all-apis` | Platform U2M / proxy authentication |
| `GET /api/v1/artifacts` | Dahlia OAuth with `all-apis` or browser session | Proxy identity |
| `POST /api/v1/artifacts` | Dahlia OAuth with `all-apis` | Proxy identity |
| `/api/v1/artifacts/{uuidv7}` | Public reads are anonymous; private reads use `all-apis` or browser session; mutations use `all-apis` | Public reads are anonymous; private reads and mutations use proxy identity |
| `/api/v1/artifacts/{uuidv7}/content` | Public reads are anonymous; private reads use `all-apis` or browser session | Public reads are anonymous; private reads use proxy identity |
| `/api/v1/vaults/**` | Browser session or Dahlia OAuth with `all-apis` | Proxy identity |
| `GET /api/v1/organizations` | Browser session or Dahlia OAuth with `all-apis`; current memberships only | Current memberships for proxy identity |
| `POST /mcp` | Dahlia OAuth with `mcp` or `mcp:read` | Databricks Apps / trusted proxy identity |
| `/healthz` | Minimal liveness | Internal liveness; anonymous external access is not guaranteed |

`accounts` is the default authentication. It serves OAuth/OIDC discovery under `/.well-known/**`. Both hosted and self-hosted deployments use the fixed public client `databricks-cli`; it requires authorization code with S256 PKCE and supports rotating refresh tokens and revocation. Its default redirect allowlist retains the released `http://127.0.0.1:1455/oauth/callback` and also accepts the Desktop callback `http://localhost:8020`. RFC 7591 dynamic client registration remains disabled. Node deployments support MCP 2026-07-28 Client ID Metadata Documents (CIMD) with pinned public-address fetching; the MCP resource is `${DAHLIA_APP_URL}/mcp` and its protected-resource metadata is at `/.well-known/oauth-protected-resource/mcp`.

OAuth access from Dahlia Desktop uses the single `all-apis` capability scope for models, Responses, artifacts, synchronization, deltas, and events. OIDC identity scopes remain separate protocol scopes.

### Meeting sync and Vault sharing

Server-account Vault changes propagate bidirectionally between Desktop and Private Web through the selected Dahlia account connection; pausing synchronization does not turn the Server record into a secondary copy. Local accounts remain device-local and create no sync transactions. Desktop API calls require `all-apis`; Server MCP reads require `mcp:read`. `app.vault_permissions` is the permission source of truth: every Vault has one immutable `user` owner identified by the authentication provider's raw user ID, while optional `user`, `organization`, and `team` members are read-only. Content rows carry only `vault_id`; PostgreSQL/Lakebase RLS and the SQLite/D1 store resolve access through the Vault permission. Files belong to a Vault independently of their `meeting_files` associations; deleting an association or meeting preserves the file. Original keys are `files/{fileId}/original`, independent of the Vault and meeting.

Desktop and Private Web mutations use `POST /api/v1/transactions`. Each UUIDv7 transaction is limited to one Vault, committed atomically, and replay-safe by transaction ID. Vault, Project, meeting metadata, and summary writes require the current canonical revision; conflicts return `409` with the Server record. File content and transcript chunks remain bounded staging uploads and are activated by a transaction. Sync schema version 2 replaces the screenshot entity with `file` and `meeting_file`; roll out Desktop, Web, and Server together.

Desktop keeps immutable operations until the Server receipt is applied. File operations include the staged content checksum (`SHA-256:` plus lowercase hex); transcript operations use `transcript:patch` with per-chunk hashes and explicit segment upserts/deletes. `400`/`411`/`413`/`415`/`422` stop as validation errors, `409` stops as a revision conflict, `401`/`403` stop as authorization errors after one token refresh, and only transport errors, `408`, `425`, `429`, and `5xx` retry automatically. The transaction response cursor records the last local commit; it never advances the separate delta pull checkpoint.

`GET /api/v1/vaults/{vaultId}/changes?cursor=...` is the durable delta feed. The first page returns a `highWaterCursor`; clients pass it on later pages so each bounded catch-up returns one final canonical state per changed entity through a stable boundary. `GET /api/v1/events` sends only SSE invalidations and opaque cursors; clients always fetch canonical data from the delta/read APIs and can catch up after disconnect or application shutdown. Server MCP remains read-only.

Vault and Project operations are committed through the domain transaction endpoint before meeting data. Projects are available for hierarchy browsing and meeting filtering but are not added to full-text or vector search. Transcript segments keep `audioSource` (`mic` or `system`) separate from nullable `speakerLabel`, which is reserved for future diarization.

### Server capabilities

`GET /api/v1/capabilities` requires the existing browser authentication or `all-apis` scope and returns supported feature versions:

```json
{ "syncVersion": 2, "meetingEventsVersion": 1, "recordingAudioVersion": 1 }
```

`syncVersion: 2` adds recording archive metadata to the synchronization contract described here: atomic transactions (transaction schema version 2), snapshot/delta recovery and receipt resolution, metadata-only reads, and separately hydrated text bodies. `meetingEventsVersion: 1` advertises the meeting-event acceptance contract described below. Feature versions are independent of entity revisions and payload schema versions. Desktop accepts syncVersion 1 and 2, meetingEventsVersion 1, and recordingAudioVersion 1; it ignores unknown fields.

Unsupported features are omitted. Stores without atomic sync support neither of these features and return `200 {}`; lack of a feature does not make the capabilities endpoint unavailable. Authentication and operational errors still return errors. Roll out Server and Desktop together; the old response fields `version` / `meetingEvents` and the old `/api/v1/sync-content` route are not supported.

### Partial text reads

Desktop requires supported `syncVersion: 1` or `2` before using partial text synchronization and must fail closed with an update-required state when this capability or the `metadata-v1` response marker is missing. Default full representations and transaction schema version 2 remain unchanged.

Add `content=metadata-v1` to snapshot, changes, meeting and file dependency reads to omit transcript bodies, summary documents (including meeting/search duplicates), OCR and caption. Canonical IDs, revisions, metadata, body presence and transcript counts remain available; snapshot/delta responses include `contentMode: "metadata-v1"`. Text hydration does not advance sync cursors.

`GET /api/v1/vaults/{vaultId}/text/{summary|transcript|file}/{entityId}?revision=N&manifest=1` returns `{ version, entity, entityId, revision, present, count, byteCount, sha256 }`. Omit `manifest=1` to read a body page and pass `nextCursor` as `cursor`. Transcript pages contain at most 500 segments and target 6 MiB; summary/file pages contain `record`. Each page includes its own count/byteCount/hash. Every request holds the Vault lock in the identity transaction, rechecks the exact revision and rejects updates with 409 or missing targets with 404; missing transcripts are never silently returned as empty meetings.

SHA-256 framing is UTF-8 `decimalByteLength:bytes` per field, with `-:` for null. Transcript input is lowercase segment UUID then text in startTime/UUID order; only text contributes to byteCount. Summary input is one nullable document; file input is nullable OCR then caption. [Shared fixtures](../../test-fixtures/text-content-v1.json) test Swift/Server agreement. Clients must validate both page and complete manifest before installing downloaded text.

`GET /api/v1/vaults/{vaultId}/search?q=...&kind=meeting|screenshot&limit=200&cursor=...` provides exhaustive FTS pages, without the Hybrid candidate cap. Results are `{ version: 1, scope: "server", items: [{ id, meetingId, snippet }], nextCursor }`; limit is 1–200 and snippets are at most 180 characters. Cursor identity includes Vault, query, kind and current ledger revision. A 409 invalidates the search cursor. Clients apply local filters before concluding enumeration and report incomplete/offline coverage explicitly; search does not download full text for retention.

### Sync history retention and recovery

The change ledger is sync-only and guarantees 90 days of delta recovery. `app.sync_vault_state` retains the latest sequence and the pruned boundary even when every change has been deleted. Every delta page checks that boundary and returns `410 sync_cursor_expired` for an expired cursor.

New devices and expired clients use `GET /api/v1/vaults/{vaultId}/snapshot`. It returns `{ items, startCursor, nextCursor }`, with at most 100 canonical `{ entity, id, revision, record }` items ordered by entity and ID. Item serialization is capped at 8 MiB per page (plus envelope overhead); a single larger record is returned alone to guarantee progress. Records are loaded incrementally, including at most one look-ahead record. Pass `nextCursor` as `cursor` and preserve `startCursor` on subsequent pages. Fetch existing transcript and screenshot endpoints for their bodies. After enumeration, fetch delta pages from `startCursor` with a fixed high-water boundary and merge their changes/deletions before removing absent local records. A `410` during enumeration or catch-up requires a fresh snapshot. Each page reauthorizes current Vault access; this is not a transaction held open across requests.

`POST /api/v1/transactions/resolve` accepts exactly the same body as the commit endpoint. It validates and normalizes the request and compares its hash without mutation or upload staging. Responses are `{ id, status: "unknown" }`, the original committed response, or `{ id, status: "committed", receipt: "compact", cursor, records: [{ entity, id, revision }] }`. Different content with the same ID remains `409 idempotency_key_reused`; another user cannot resolve the receipt. Resolve before restaging/retrying. An unknown result must keep the original ID, body and base revisions. Compact results acknowledge the queued operations, preserve later local edits, and require a canonical refresh without advancing the pull checkpoint to the receipt cursor. The legacy commit endpoint returns `410 transaction_receipt_expired` instead of passing a compact result off as an ordinary receipt.

### Meeting events and recording indicators

`meeting_events` is Server-only domain history, separate from the 90-day synchronization ledger. Server records `meeting_created`, `meeting_updated` (changed field names only), and `meeting_deleted` atomically with accepted meeting mutations. Desktop sends `tag_added`, `tag_removed`, `recording_started`, `recording_ended`, and `segment_rotated` through `meeting_event:create` transaction operations, with `baseRevision: null` and the event UUID as `entityId`. Event data contains `meetingId`, `kind`, `occurredAt`, and only the relevant `sessionId`, `relatedId` (local numeric tag ID or segment UUID), `audioSource` (`mic` / `system`), and positive `segmentIndex`. Tag names, field values, audio, and file paths are never included. A segment rotation means switching to the next physical segment, not successful finalization; initial file creation is not a rotation.

`GET /api/v1/capabilities` advertises `meetingEventsVersion: 1`. Desktop queues events only after confirming this capability for the current Server Vault, rechecks before upload, and omits diagnostic uploads if the Server has been downgraded. Unsupported and Local accounts do not record events. Normal transactions and event IDs are independently idempotent; different content with an existing event ID is rejected. Owner authorization and session-to-meeting relationships are checked before accepting events. This is a diagnostic history of accepted operations, not a tamper-proof audit trail or telemetry.

The SQL view `recording_sessions` groups recording start/end events by Vault, meeting and session ID. Meeting list/detail responses expose derived `isRecording`; a session with a start and no end displays “Recording” / “録音中” in the list, detail and sidebar. Existing SSE meeting invalidations refresh these indicators. There is no heartbeat or timeout: offline Desktop recording remains marked active until its end event synchronizes. Events are not included in snapshots or copied into another Desktop's local recording runtime. Existing historical operations are not backfilled.

History has no new age limit. Deleting a meeting removes related IDs, source/segment details and changed field names from its events, retaining identifiers, event kinds and timestamps. Deleting its Vault or owner account removes the events. PostgreSQL enforces RLS on both the event table and its invoker view. Inspect history directly in the database; there is no event browsing API or UI. Deploy Server migrations and Server first, then Desktop.

Late events for a missing, inactive, or deleting meeting return `410 meeting_event_parent_unavailable`. Desktop discards only that event transaction so diagnostic uploads cannot block content sync or recreate a deleted meeting. Meeting reads check indexed start/end events directly; the aggregate view remains available for investigation without making each SQLite read group unrelated Vault history.

Receipt bodies are retained for 90 days. Transaction ID, owner, Vault, request hash, result IDs/revisions and commit cursor remain until the existing account-deletion contract removes them. Canonical meeting data has no new retention limit; lightweight receipt storage is not constant-sized.

Cleanup is disabled unless explicitly invoked with `--apply`:

```bash
pnpm db:prune-sync-history --apply
# Packaged operator command:
pnpm db:prune-sync-history:prod --apply
```

Without the flag the command exits without opening the database. Configure an operator scheduler to run it daily only after recovery verification. It uses Server time, prunes a contiguous prefix older than 90 days in batches of at most 1,000, compacts receipt bodies in bounded batches, and shares the Vault commit lock. Boundary changes and deletion commit atomically; failures and overlapping runs can be retried. Output contains only success/failure and aggregate counts, never content or identifiers. D1 meeting-sync restrictions remain in force.

Roll out the forward migrations, then **all** Server instances, then compatible Desktop/Web clients; test recovery before enabling the scheduled command. Do not enable cleanup while older Server instances can still write receipts without result metadata. Older clients must upgrade to recover expired cursors/receipts. Production migration and scheduler activation are separate operator actions.

`GET /api/v1/vaults/{vaultId}/meetings` returns at most 200 meetings. Pass its opaque `nextCursor` as `cursor` to continue the same date-ordered Vault or Project listing. `query_meetings` exposes the same cursor contract. Search results remain a bounded relevance-ranked page and do not return a continuation cursor.

The optional `projectScope=direct` requires `projectId` and returns only meetings directly assigned to that Project. `projectScope=unassigned` forbids `projectId` and returns only meetings without a Project. Omitting `projectScope` preserves the existing Project-and-children listing. Both scopes support the same cursor pagination.

The Private Web sidebar displays collapsible Projects and their meetings, with dates and the current meeting highlighted. Only the selected Vault’s Projects and meetings appear in the sidebar, without a Vault-name heading; switch Vaults from the account menu. Meetings without a Project remain accessible under **Unassigned**. Vault routes determine the selection; other pages restore the last selection per user and Personal/Organization scope from tab-scoped session storage, defaulting to the first available Vault. Expand controls are separate from detail links; meetings load on expansion, with **Show more** for subsequent pages. The sidebar footer shows the account name and current Vault (or Personal/Organization scope). Its compact account menu uses icons and separate Vault and Organization sections; the current Vault has a checkmark and each Vault links to its details. The account row opens account information. The remaining entries provide Personal/Organization switching, Vault and Organization management, account settings and capability-gated extension links. **Members** appears inside the **Organizations** section for platform administrators, including deployments without sharing. Session-authenticated accounts can sign out from the bottom of the menu; sign-out errors stay visible for retry. Proxy-authenticated deployments omit sign-out because their identity is managed upstream. Selection and expansion are stored per user in tab-scoped session storage. The initial selection is Personal; a revoked Organization selection returns to Personal.

The Artifacts list and viewer are temporarily hidden from Private Web pending the Files API transition. `/artifacts` and `/artifacts/:id` redirect to `/dashboard`; existing artifact APIs, storage, and API content URLs remain unchanged.

Built-in dashboard links update the main area through browser history without reloading the document. The sidebar retains its loaded Project/meeting lists, expansion state, and scroll position; selection highlights and the selected Project ancestry update in place. Back/Forward follow the same path, and each main page starts with fresh detail state. Keyboard focus moves to the new content without outlining the whole page; interactive controls retain their focus indicators. Modified clicks, downloads, authentication, and unregistered routes retain normal browser navigation; registered extension routes use SPA navigation. Account and permission writes refresh the shared account menu and session capabilities, including Organization/Team membership, Vault sharing, and administrator changes. Sync transactions refresh canonical data without re-fetching the session. Read requests and failed writes do not trigger this refresh. Transactions notify once, only after validating a committed receipt from the initial request, resolution, or retry; unknown resolution results and invalid receipts do not refresh projections. Protected API responses with status `401` return to sign-in with the current path; `403` authorization failures and `409` conflicts remain page errors.

SSE connection/reconnection and invalidation notifications, and validated sync transaction receipts, refresh mounted data consumers without reloading the document. Reads are coalesced to one active request and one trailing refresh per consumer. Background refreshes retain the selected meeting tab, sidebar expansion, scroll position, search filters, and loaded list range. Lists re-read from the first page through the loaded item count using fresh cursors; unchanged records keep their references. Transient failures retain content with a Retry action, while 401/403/404 clear the affected data. Navigation aborts obsolete reads; changing user or Organization clears the previous scope. SSE cursors are reconnect hints, never persisted as completed data checkpoints; reconnect and coming back online re-fetch current data. Editing, creation/deletion, and Organization switching use the same data refresh and History API navigation paths. A different meeting still starts on Summary.

The meeting detail header and body appear only once meeting and Vault data are available, without flashing a placeholder title or loading document; read failures retain their error and Retry action. Meeting details follow the desktop document layout: title, date/duration, Project and summary tags above **Summary**, **Screenshots**, and **Transcript** tabs. Project names load independently, so a failed name lookup does not hide meeting content or its Project link. Summaries retain their headings, lists, tables, line breaks, and timestamp labels. Transcript rows show elapsed `HH:mm:ss` from the recording start, falling back to the first transcript segment when the recording start is absent, as Desktop does without session timing. The current Server transcript contract does not expose recording-session timing, so resumed-session pause offsets cannot be applied. Owner-only editing is collected in **Actions**; read-only members do not see those controls. Recording, notes, and conversation analysis controls are omitted because these features are not available in Private Web. New meeting and navigation labels use Japanese for Japanese browser locales and English otherwise.

`GET /api/v1/vaults` accepts mutually exclusive `userId` and `organizationId` filters. No parameter means the authenticated user's own `userId`. A user filter returns owned Vaults and only permits the authenticated user's ID (another user is `403`). An Organization filter requires current membership (`403` otherwise), and returns only Vaults shared to that Organization or to one of the user's Teams within it. Owning a Vault or access through a different Organization is insufficient for this filter. Multiple matching grants produce one row. Empty, whitespace-containing, control-containing, over-200-character IDs and simultaneous filters return `400`; IDs are opaque auth IDs, not necessarily UUIDs.

**Client compatibility:** the default Vault listing now returns owned Vaults, rather than all accessible Vaults. Clients needing all accessible Vaults must union the default listing with each `organizationId` listing by Vault ID. `GET /api/v1/organizations` lists the authenticated user's Organizations in both accounts and header modes and accepts browser or `all-apis` gateway authentication; sharing-disabled deployments return an empty array. Desktop Vault discovery performs this union. Update Desktop along with Server to preserve shared Vault discovery; older Desktop versions continue synchronizing already-registered Vaults but will not discover additional shared Vaults through the default list.


Files API storage currently requires the Databricks Volume backend. `POST /api/v1/files` accepts the file itself as an uncompressed raw body, with required query parameters `id` (client-generated UUIDv7), `vaultId`, `name` (1–255 characters), and `source` (`upload` or `screenshot`). Optional `width` and `height` are positive integers up to 33,554,432. Query values must be URL-encoded; OCR and captions belong in metadata mutations, not URLs. Use `Content-Type` for the MIME type and a required `Content-Length` up to 64 MiB. The Server counts the received bytes and computes SHA-256 while streaming to storage, checks that the received length matches `Content-Length`, and records `size`, `checksum` (`SHA-256:` plus lowercase hex), and `offset: 0`. Clients do not submit these fields. A missing length returns `411`, an excessive length returns `413`, and unsupported content encoding returns `415`.

```http
POST /api/v1/files?id=<UUIDv7>&vaultId=<UUID>&name=capture.png&source=screenshot&width=1800&height=900
Content-Type: image/png
Content-Length: 12345

<raw PNG bytes>
```

The response contains file metadata, including the computed `size` and `checksum`, `contentURL`, and available `variants`. A completed new upload returns `201`; retrying an uploaded ID with identical bytes, MIME type, and source returns `200` without changing its bytes, name, or metadata. Different content for an uploaded ID returns `409`. Failed uploads remain retryable; partial storage objects are removed, with failed removals retried by the storage deletion queue. Node SQLite serializes storage mutations across instances using an adjacent `.storage-lock` SQLite file; this does not lock the application database during network I/O. Keep that lock file in place while any instance is running. PostgreSQL uses per-key advisory locks for concurrent storage workloads. The canonical `uri` is the full `/Volumes/{catalog}/{schema}/{volume}/files/{fileId}/original` path. Device-local paths never cross this API. The former JSON reservation POST and upload PUT are no longer supported; deploy Server and Desktop changes together.

Uploads remain private staging until a revision-checked `file:upsert` commits through `/api/v1/transactions`; its checksum must match the Server result and its `metadata` patch preserves other keys. Replacing bytes requires a new file ID. Unpublished uploads expire after 24 hours and can be uploaded again. `meeting_file:upsert` associates an existing canonical file and meeting in the same Vault, with an independent association ID, nullable `capturedAt` and `sessionId`, and `createdAt`. A file may be attached to multiple meetings. `meeting_file:delete` only unlinks; `file:delete` rejects remaining associations, which may be removed earlier in the same atomic transaction.

`POST|PUT|PATCH /api/v1/files/{fileId}/metadata` update metadata on an owner's committed file with a JSON body containing required `baseRevision` and `metadata`. Allowed metadata keys are `width`, `height`, `ocr_text` (up to 20,000 characters), and `caption` (up to 500 characters). Omitted keys are preserved; `null` clears OCR or caption. `source`, bytes, `size`, and `checksum` cannot be changed. Invalid fields return `400`, missing/staged files and non-owner access return `404`, and stale revisions return `409` with the canonical conflict record. Success returns `200` with the committed file metadata, content URL, variants, and new revision. All three metadata mutation methods share the same partial-update semantics and transaction, search, and delta machinery as Desktop metadata updates; clients receiving a conflict refetch/reconcile before retrying.

```http
PATCH /api/v1/files/{fileId}/metadata
Content-Type: application/json

{"baseRevision":3,"metadata":{"ocr_text":"Recognized text","caption":"Quarterly revenue"}}
```

`GET /api/v1/files/{fileId}/metadata` returns canonical metadata, a content URL, and available named variants. File lists include the same content URL and variants. `GET /api/v1/vaults/{vaultId}/files` and `GET /api/v1/vaults/{vaultId}/meetings/{meetingId}/files` return at most 200 rows ordered by ID, with `nextCursor` for the next page. Pending files are excluded. MCP `get_meeting_screenshots` reads the screenshot projection and retains chronological pagination and bounded search.

`GET` / `HEAD /api/v1/files/{fileId}` reads the original and supports byte ranges. HEAD returns size, MIME type, ETag, and other read headers without a body. The former `/api/v1/files/{fileId}/content` route and metadata PATCH at `/api/v1/files/{fileId}` are removed. `/api/v1/files/{fileId}/variants/{variant}` supports `thumb_480` (480px, grid), `thumb_1280` (1280px), `thumb_1568` (1568px, preview), and `thumb_1920` (1920px). All sizes are long-edge limits. Variants preserve aspect ratio without upscaling and generate quality-80 WebP on first request, persisted at `files/{fileId}/variants/v1/{variant}.webp`, and reused across restarts. Generation uses the existing Node `sharp` dependency, coalesces requests, and is bounded to two active jobs and 32 queued/active jobs. Storage failure fails the request so it can retry; the variant endpoint never substitutes original bytes. Runtimes without a transformer advertise no variants. Every metadata, original, and variant read uses current Vault permissions. Original and variant ETags distinguish the recipe version. Responses use `Cache-Control: private, no-cache`: clients may store bytes but must revalidate before reuse so each reuse checks current Vault access. Authorized `GET` / `HEAD` requests with a matching `If-None-Match` (including weak tags, tag lists, and `*`) return a body-free `304` before image generation or storage reads, unless `If-Unmodified-Since` is also present: its storage precondition is checked first with `HEAD`, without applying ranges. Metadata is rechecked against the response-header snapshot before storage access to reject a file ID replaced between those lookups. `Vary: Authorization, Cookie` separates credential-dependent browser cache entries. Storage error responses use `no-store`. Current Vault access and variant availability are checked before revalidation, so deleted or inaccessible files still return `404`. Package-root imports remain Worker-safe.

Web screenshot grids use `thumb_480`, open `thumb_1568`, and offer an original link. Unsupported transformers advertise no variants; generation failures are shown rather than silently replaced by original images. `MeetingSyncService.readFileContent(identity, fileId, variant)` shares authorized generation and cached streaming reads with server-side consumers; HTTP delivery adds response headers separately. The unpublished `thumbnail` name is removed and returns 404.

`GET /api/v1/vaults/{vaultId}/meetings/{meetingId}/transcript` returns up to 10,000 segments in chronological order. Pass `nextCursor` as `cursor` to continue; MCP `get_meeting_transcript` uses the same page contract.

Explicit Organization and Team sharing is disabled unless `DAHLIA_SYNC_SHARING_ENABLED=true`. Disabled deployments do not expose permission mutations or member reads; owner sync and owner reads remain available.

In accounts mode, owners use Better Auth Organizations, invitations, and Teams. In header mode, every validated proxy user is projected into the visible `external` Organization; the first user is its immutable owner and belongs to the `External` default Team, while later users join only the Organization. Organization owners manage Team membership from the same Web page. Vault owners explicitly grant read-only access through `PUT|DELETE /api/v1/vaults/{vaultId}/permissions/organizations/{organizationId}` or `/permissions/teams/{teamId}`; direct user member rows remain schema-only. PostgreSQL/Lakebase always migrate the generated `auth` baseline before the application baseline. RLS receives only transaction-local `app.user_id` and resolves current membership from `auth.member` and `auth.team_member`.

The exhaustive `/api/v1/vaults/{vaultId}/search` endpoint orders by document ID. This keeps its pages stable when writes to another Vault change corpus-wide relevance scores.

### Common search API

`POST /api/v1/search` and the read-only MCP `search` tool share the same request and result order. The authenticated JSON body requires `vaultId`; optional fields are `query` (default empty; trim, then at most 500 UTF-16 code units), `kind` (`meeting`, `screenshot`, `project`; omitted means all), `projectId` (including descendants), timezone-qualified `from`/`to` (inclusive/exclusive), and `limit` (per kind, default 50, range 1–100). Unknown fields, non-string queries, invalid dates and reversed ranges return 400; bodies over 16 KiB return 413. No `q` alias is accepted. Empty queries return recent items. Meeting dates are creation dates, screenshot dates are capture dates; date-filtered projects must have a meeting in the selected period, including descendants.

The response is `{ vaultId, meetings, screenshots, projects, limited: { meeting, screenshot, project } }`. Each hit has `id`, `kind`, `title`, ISO `date`, `snippet`, and applicable `meetingId`, `projectId`, `projectPath`, `fileId`, or `meetingCount`. Arrays preserve relevance order, are bounded to 100 per kind, and expose no scores, vectors or cursor. A `limited` flag means the selected cap was reached; refine filters rather than treating this as exhaustive enumeration. Responses use `Cache-Control: no-store`; search input is never logged. Permission and project/date filters are applied before FTS/vector candidate limits, query embedding is shared once across kinds, and current Vault access is rechecked before returning. Projects match normalized name/path terms and sort by recent meeting activity.

Capabilities advertise `searchVersion: 1`. Desktop Server accounts use these ranks without hydrating retained-out bodies; pending local meetings, images and projects have separate sections. Offline, older servers, unsynchronized metadata, tag filters and multiple selected projects use explicitly labeled device-only search. Local accounts retain existing search. The legacy GET search endpoint above keeps exhaustive FTS/cursor behavior for existing clients and the local content broker.

Web opens search from the sidebar or Cmd/Ctrl+K, shows six recent meetings initially, and provides project/date/type filters, progressive results, image preview and detail navigation. Arrow keys/Enter select results, Cmd/Ctrl+1–9 activate numbered results, and Escape closes preview/search with focus restoration. Requests debounce for 300 ms, pause during IME composition, cancel obsolete queries and clear on Vault changes; background refresh preserves input and scroll. Text follows the existing English/Japanese browser language setting.

### Server hybrid search

Meeting and screenshot search is tokenized by the Server; it never reads Desktop's SQLite tokenizer or token data. Meeting search covers name, description, and visible summary text. Screenshot search covers OCR and caption. Original transcripts remain synchronized but are not searchable. Queries are limited to 500 characters and 16 AND-combined tokens. Node uses the pinned Lindera IPADIC WASM package, while Cloudflare Workers use `Intl.Segmenter`; changing runtime for an existing database requires recreating it or fully resynchronizing every meeting.

`app.search_documents` is the shared rebuildable projection for meetings and screenshots. PostgreSQL uses its generated `tsvector` with GIN, SQLite uses an external-content FTS5 table, and Lakebase uses `lakebase_text` with BM25. D1 sync is fail-closed until its multi-statement writes use D1's atomic `batch()` API. Lakebase Search must be enabled by an operator before deployment; startup stops when the required extension cannot be loaded. After the first full synchronization, update BM25 corpus statistics once with:

```sql
VACUUM app.search_documents;
```

Node also processes uploaded, canonically attached meeting images when `DAHLIA_CAPTIONING_MODEL` is set. The Databricks App service principal analyzes the existing bounded `thumb_1280` WebP variant; OCR stays in the original language (20,000 characters maximum), and captions use the owner's output language (500 characters maximum). Images and generated text are sent to the configured provider without logging request content. File-level durable jobs use five-minute leases and retry transient failures after restart. They preserve populated OCR/captions, accept empty OCR, and validate current ownership, checksum and revision before atomically committing canonical text, deltas, search projection and embedding jobs. Setting changes do not reanalyze completed images. Missing model configuration disables the corresponding worker; Workers do not run these Node jobs. The capabilities API advertises `imageAnalysis: true` only when Node has constructed the worker; Desktop retains device analysis when it is false or absent (including older servers). Capability fetch failures retain the job for retry. Device fallback uses the Server account language settings when available, otherwise its existing device language settings. Files API storage currently requires Databricks Volumes.

### Account language settings

Authenticated users read `GET /api/v1/account/settings` and send `PATCH` with `outputLanguage` (`ja`, `en`, `zh`, `ko`, `fr`, `de`, `es`) and/or `analysisLanguages: { scope: "all" | "selected", identifiers: [...] }`. The scope and identifiers are one field; selected requires at least one identifier. Both routes return `{ settings }`; GET returns null before initialization. PATCH changes only supplied fields and returns the full canonical settings. Requests are limited to 8 KiB, and another identity's settings cannot be addressed.

Desktop initializes absent settings using its current local values and `initialize: true` with both fields; conditional INSERT preserves another device's settings. Before initialization, image analysis uses Japanese output and all languages. Same-field updates use the last server write. The existing SSE stream emits `account_settings` invalidations without settings content or a settings revision; clients refetch after reconnect and on settings display to recover missed notifications.

Desktop keeps these settings in memory only and disables edits when unavailable. Existing Server working copies can start, continue and stop recording offline with expired credentials or settings not yet fetched. Audio, finalized transcripts, images and queued sync operations remain on the existing local persistence path; only sync waits for reconnection or reauthentication. Local Account AI and device recording/transcription settings remain local. Server-account summaries are generated asynchronously on supported Node servers using the account output language; Local Account generation stays on Desktop.

Set `DAHLIA_EMBEDDING_MODEL` to enable asynchronous semantic indexing on Node; an empty or missing value keeps it off. `DAHLIA_SEARCH_EMBEDDING_DIMENSIONS` defaults to `1024` and accepts powers of two from 32 through 1024. The App service principal calls the Databricks embedding endpoint, and content or credentials are never stored in the queue. Lakebase uses `lakebase_vector` with `lakebase_ann`; other PostgreSQL deployments use pgvector's `vector` extension with HNSW. Install `vector` as a database operator before enabling embeddings when the application role cannot create extensions. SQLite performs exact cosine ranking in Node. Search automatically combines the top 100 FTS and vector candidates with RRF and falls back to FTS when embeddings are absent, rebuilding, or unavailable. Document text and the user's search query are sent to the configured embedding provider; Dahlia does not persist or log query text.

### Server summary generation

`GET /api/v1/capabilities` includes `summaryGeneration: { version: 1, methods: ["transcript"] }` on Node with the Databricks backend. Methods come from the registered generators. Workers and unsupported backends report `summaryGeneration: { version: 0, methods: [] }`. An empty capabilities object also means summary generation is unsupported. There is no separate summary methods endpoint.

Account settings include `summary: { method: "transcript", methodSettings: { transcript: { model, reasoningEffort, detail } } }`. Select a model from the shared `/api/v1/models` catalog; do not use the legacy initial value `gpt-5.4` unless it is actually available. Summary calls share Gateway short-name/schema and auto-review alias resolution. Reasoning choices come from the model catalog and accept `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`; detail accepts `concise`, `standard`, `detailed`, or `eventSession`. Defaults are `medium` and `detailed`. Configure these in Web Settings or Desktop AI Summary settings. PATCH has no `settings` wrapper and merges only supplied fields at every summary nesting level: `{ "summary": { "methodSettings": { "transcript": { "detail": "concise" } } } }` preserves the model, reasoning effort, method and other settings. Unknown keys, methods and invalid values are rejected. `outputLanguage` stays at the account settings root and retains its existing scope. Uninitialized accounts return `{ "settings": null }`; `initialize` still creates settings only if absent. Existing database columns and queued job settings are retained.

Owners start `POST /api/v1/vaults/{vaultId}/meetings/{meetingId}/summary` with `{ id: "<UUIDv7>", detail?: "concise" }` (8 KiB maximum). It returns 202 Accepted and `{ job }`, with `Location: /api/v1/vaults/{vaultId}/meetings/{meetingId}/summary/job`. Reuse the same ID and body after an uncertain response. A different request with the same ID or another active job returns 409. GET on that Location path returns the latest `{ job }` or null. State is `pending`, `processing`, `succeeded`, or `failed`; the response includes the fixed method/settings/language, attempts, creation time and a bounded error code. Retry a failed job with a new ID. Both routes authenticate the current Vault owner and never accept an executor identity from the request body. Browser writes require the configured origin.

Jobs survive client closure and Server restart. A 5-minute lease fences completion; each generation attempt has a 4-minute deadline and at most three attempts. The Databricks App SP sends Responses through the existing fetch adapter with `store: false`, strict structured output and the authenticated executor's `user_id` request tag. Interactive Gateway OBO behavior is unchanged. No new SDK or environment secret is required.

The transcript method reads only canonical transcript, images and meeting/Project context. It samples up to 24 image bodies while including all available OCR/captions within the documented input bounds. Invalid output, changed input, deleted meetings and summary revision conflicts do not replace existing summaries. Successful canonical transactions update title/description, summary, search and delta state atomically with the job. Desktop waits for synchronization before starting and applies the result through normal delta sync without an echo. Export is a separate manual action for Server accounts. Web and Desktop refetch job state when reopened; polling does not carry document content.

Custom Node entry points can import `SummaryService`, `SummaryWorker`, and `createTranscriptSummaryMethod` from `@dahlia-ai/server/node`, use `applicationStore.summaryJobs`, pass `summaryService` to `createApp`, and start/stop the worker with the process lifecycle. See [the summary ADR](../../docs/adr/server/summary-generation.md) for input limits and the future Gemini method boundary. Audio upload/retention is unchanged by this feature.

### Artifact API

`POST /api/v1/artifacts` accepts an uncompressed raw body with a required `Content-Length` up to 64 MiB, creates a private artifact with a Server-generated canonical lowercase UUIDv7, and returns its mutable `/api/v1/artifacts/{uuidv7}` resource in `Location`. The response `viewerUrl` contains the human-facing `/artifacts/{uuidv7}` URL. Storage version filenames under the `artifacts/` prefix start with Unix time milliseconds and include a collision-resistant suffix. Clients may supply a safe extension with `Content-Disposition: attachment; filename="name.ext"`; otherwise HTML uses `.html`, other text uses `.txt`, and binary content uses `.bin`. `PUT /api/v1/artifacts/{uuidv7}` replaces an existing artifact owned by the caller and requires the original `Content-Type`; it never creates a missing ID. `PATCH` accepts only `{"visibility":"private"}` or `{"visibility":"public"}`, and `DELETE` removes bytes before metadata so a storage failure can be retried. There is no history, expiry, malware scan, HTML sanitization, or per-user share API.

`GET /api/v1/artifacts` lists the current personal workspace in descending UUIDv7 order, 50 records at a time. Pass the opaque `nextCursor` response as `cursor` to fetch the next page. `GET /api/v1/artifacts/{uuidv7}` keeps its existing raw-byte response; request `Accept: application/vnd.dahlia.artifact+json` for metadata. `GET` and `HEAD` on `/api/v1/artifacts/{uuidv7}/content` always return bytes. If an `Authorization` header is present, read endpoints validate only that OAuth credential; otherwise they accept the signed-in browser session. Browser sessions do not authorize artifact mutations.

All storage backends stream authorized `GET` and `HEAD` responses through Dahlia, forward `Range` and `If-Unmodified-Since`, and apply a CSP sandbox so uploaded HTML cannot inherit the Dahlia application origin. Storage URLs and credentials are never returned to clients. The Private Web list and viewer are temporarily unavailable; their routes redirect to `/dashboard`.

### Artifact MCP

`POST /mcp` is a stateless, modern-only MCP 2026-07-28 endpoint. `mcp` exposes every MCP tool, including the four artifact mutations and all synchronized-content reads; `mcp:read` exposes only the Project, meeting, transcript, and screenshot read tools, including Project-filtered meeting queries. Each tool uses the same authorization as its REST API. Tool content is UTF-8 or canonical RFC 4648 base64, decoded to at most 8 MiB. MCP requests are rejected above 12 MiB before JSON parsing, including streamed requests without `Content-Length`. Tool results contain the artifact ID, canonical viewer URL, content type, visibility, and a resource link to the content endpoint, never artifact bytes or storage URLs. Streaming uploads larger than 8 MiB remain available through the REST API.

In `accounts` mode, `/mcp` requires a DPoP-bound access token for the exact MCP resource and either `mcp` or `mcp:read`; only tools covered by the granted scope are registered. In `header` mode, authentication is delegated to the trusted proxy and Dahlia derives ownership from its verified forwarded identity headers. Databricks Apps exposes custom MCP servers at `/mcp`; its proxy has already authenticated the request, and `X-Forwarded-Access-Token` is not used for artifact storage. A present `Origin` must match the configured application origin; non-browser clients may omit it.

`DAHLIA_STORAGE_BACKEND` selects `local`, `s3`, `databricks`, or `r2`. Node defaults to `local` under `DAHLIA_STORAGE_LOCAL_PATH=.data/storage`. Databricks uses `DAHLIA_STORAGE_DATABRICKS_VOLUME_PATH=/Volumes/<catalog>/<schema>/<volume>`. S3 uses `DAHLIA_STORAGE_S3_BUCKET`, optional `DAHLIA_STORAGE_S3_ENDPOINT`, and the standard `AWS_*` credential variables. Workers must explicitly select `r2` with the `DAHLIA_STORAGE` binding or `s3`; they reject the local default.

`header` reads the authenticated email from `X-Forwarded-Email` by default. Override the email header name with `DAHLIA_AUTH_HEADER`, for example `Cf-Access-Authenticated-User-Email`. `X-Forwarded-User` supplies the stable user ID and `X-Forwarded-Preferred-Username` supplies the display name; when absent, the email remains the user ID. The upstream proxy must remove client-supplied identity headers, write the verified values itself, and prevent direct access to the Server.

`DAHLIA_APP_URL` sets the canonical public application origin used for OAuth metadata and browser mutation checks. When it is absent, Dahlia uses `DATABRICKS_APP_URL`, then falls back to `http://localhost:5173` for local development.

## Provider and model configuration

The AI backend uses the OpenAI Responses-compatible contract and is independent of the database. Select `databricks`, `cloudflare`, or `openai` with `DAHLIA_AI_BACKEND`; it defaults to `openai`. While the selected non-Databricks backend has no `OPENAI_API_KEY`, `/api/v1/models` returns an empty standard model list and a Codex catalog with no picker-visible models, while Responses returns `503 provider_not_configured`.

`GET /api/v1/models` returns the standard OpenAI `object` and `data` fields together with the `models` catalog required by Dahlia's bundled Codex. Omitting `client_version` selects the latest supported bundled version, currently `0.153.4`; callers may also request `client_version=0.153.4` explicitly. Other explicit versions return `400 unsupported_codex_client_version`. Each AI backend returns both representations directly; model discovery no longer reads Model Alias rows. OpenAI and Cloudflare currently return a fixed mock catalog containing `gpt-5.6-luna`. Cloudflare maps that ID to `openai/gpt-5.6-luna` for inference. The Server owns the reserved `codex-auto-review` override independently of every backend. Set `CODEX_AUTO_REVIEW_MODEL` to expose that alias as `Codex Auto Review` and route automatic approval reviews to the configured upstream model; an empty or missing value uses the backend model normally, including a discovered `codex-auto-review` service. The environment override wins over any backend model with that reserved ID and is forwarded verbatim, without Databricks schema prefixing. Codex picker and runtime metadata comes from Dahlia-owned model catalogs; models without pinned Codex metadata use the OSS default of `low`, `high`, and `max` reasoning effort with `max` as the default. OpenAI-internal transport, hosted-tool, service-tier, and canonical-model lifecycle fields are not inherited by aliases. Updating the bundled Codex requires updating this Server catalog and its contract test in the same change.

Dahlia owns a single expanded model catalog, `src/ai-gateway/databricks-models.json`. It contains Databricks public IDs such as `gpt-5-6-terra`, additional GLM/Kimi/DeepSeek/Gemini definitions, and the original dotted Codex IDs needed by OpenAI/Cloudflare and to suppress built-in picker entries. Every entry contains its own metadata; there is no runtime inheritance, `base_model`, or alias schema. Catalog entries enrich discovery results; they do not publish unavailable models or rewrite inference request IDs.

To regenerate the catalog from an OpenAI Codex checkout at `rust-v0.153.4`, run `node scripts/generate-databricks-models.mjs /path/to/codex/codex-rs/models-manager` from `apps/server`. The generator copies selected runtime fields, expands both ID spellings, assigns display names, and adds non-OpenAI models. It also updates the separate fallback prompt. Codex source files are only used during generation; Server startup reads the committed catalog. Review generated changes and update the helper/version contract when advancing the referenced Codex release.

Display names in both `data[].display_name` and `models[].display_name` use a non-blank provider name, then the matching catalog definition, then the original ID. Unknown IDs are not reformatted. GPT reasoning levels and defaults follow Codex 0.153.4, including `ultra` where supported (Astra and Sol default to `low`, Terra and Luna to `medium`). GLM/Kimi/DeepSeek use `low`, `high`, and `max`, defaulting to `max`; Gemini 3.8/3.7 Flash definitions use `low`, `medium`, and `high`, defaulting to `medium`.

Codex 0.153.4 `models-manager` merges remote catalogs into its built-in catalog by exact slug for custom providers, and resolves runtime metadata by longest-prefix matching (with limited `provider/model` namespace support). It does not translate dots into hyphens. The Server therefore returns exact discovered IDs and hidden entries for built-in slugs to suppress unavailable built-in picker choices. Hidden entries retain their display names and reasoning metadata with empty instruction templates. The authoritative `model_catalog_json` startup option bypasses remote catalog refresh, so Desktop continues using the Server `/models` endpoint for discovery. See the [pinned manager implementation](https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/models-manager/src/manager.rs). When upgrading Codex, regenerate and review the metadata and built-in slug coverage alongside the helper version.

The first authenticated user becomes the initial administrator. Administrator roles are stored in Better Auth's `auth.user.role`; additional registered users can be promoted or demoted under `/admin/members`.

OpenAI or another OpenAI-compatible provider:

```dotenv
DAHLIA_AI_BACKEND=openai
OPENAI_API_KEY=...
# OPENAI_BASE_URL=https://api.openai.com/v1
```

Non-local provider URLs must use HTTPS. Model Alias management UI and `/api/admin/models` endpoints have been removed. The unreleased baseline also removes the Model Alias table, CRUD methods, and exported types. `GatewayService` takes `(config, transport?)` without a database store.

Databricks native OpenAI Responses API:

```dotenv
DAHLIA_AI_BACKEND=databricks
CODEX_AUTO_REVIEW_MODEL=system.ai.gpt-5-6-luna
DATABRICKS_HOST=https://<workspace-host>
DATABRICKS_MODEL_SCHEMA=dahlia.ai
DATABRICKS_CLIENT_ID=<app-service-principal-client-id>
DATABRICKS_CLIENT_SECRET=<app-service-principal-secret>
DAHLIA_DATABASE_TYPE=lakebase
LAKEBASE_ENDPOINT=<injected from the postgres app resource>
```

Databricks Apps supplies `DATABRICKS_HOST`, App service principal credentials, and `X-Forwarded-Access-Token`. Dahlia sends the forwarded user token as Bearer authentication only to `DATABRICKS_HOST/ai-gateway/mlflow/v1/responses`; it does not persist, log, or forward the proxy header itself. The Lakebase connector and model discovery independently use the App identity.

`GET /api/v1/models` uses the App service principal to list all pages of Model Services under the required `DATABRICKS_MODEL_SCHEMA` (`catalog.schema`, for example `dahlia.ai`; specify catalog and schema names in lowercase). Names containing `embedding` are excluded; all remaining services are exposed in the standard `data` list. The Codex `models` catalog includes discovered entries defined in the provider catalog (including Gemini 3.8/3.7 Flash), supported fallback families (`gpt-*`, `glm-*`, `kimi-*`, `deepseek-*`), and the reserved `codex-auto-review` alias. Desktop and Web model selectors hide `codex-auto-review`; the API still returns it for automatic reviews. Hidden bundled catalog entries remain to suppress Codex built-in picker defaults. Discovery does not inspect `supported_api_types` or issue individual GETs. Operators must include `embedding` in embedding service names and register Responses-compatible models under other names. The configured `CODEX_AUTO_REVIEW_MODEL` override is trusted without capability discovery. Model IDs are returned as short names such as `gpt-5-6-luna`; the Databricks backend prefixes that configured schema when forwarding Responses. Fully qualified model IDs from clients are rejected. The Server-controlled `CODEX_AUTO_REVIEW_MODEL` override is exempt and is sent unchanged. Databricks requires `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; Apps injects both at runtime. Desktop authorization requests `all-apis`; the App keeps the `ai-gateway` and `files` OBO scopes.

The Worker-safe `AIGatewayBackend` interface provides `listModels(request)` and `responses(body, context)`. `RequestBody` is the shared Responses payload; `input` may be omitted (for example with a stored prompt), and nullable `max_output_tokens` / `stream` values are forwarded unchanged; `RequestContext` carries verified `identity.userId`, incoming headers, cancellation, and an optional Server-resolved `upstreamModel`. Implementations read only necessary incoming headers and construct upstream headers explicitly. Databricks sends the verified user ID as `user_id` in `Databricks-Ai-Gateway-Request-Tags` for upstream usage attribution; client-supplied tags cannot override it. User IDs and content are not written to Dahlia diagnostic logs.

Cloudflare AI Gateway:

```dotenv
DAHLIA_AI_BACKEND=cloudflare
OPENAI_API_KEY=<cloudflare-api-token>
OPENAI_BASE_URL=https://api.cloudflare.com/client/v4/accounts/<account-id>/ai/v1
```

This uses Cloudflare's account-level OpenAI-compatible REST API and its default gateway. Dahlia disables Cloudflare payload logging on forwarded requests.

## Local Node deployment

Node 22.13 or newer is required. Dahlia Server owns its pnpm version, lockfile, and dependency build allowlist independently from the other applications:

```bash
cd apps/server
corepack enable
cp .env.example .env.local
pnpm install --frozen-lockfile
pnpm dev
```

The development scripts load `apps/server/.env.local`. SQLite at `apps/server/.data/dahlia-auth.sqlite` is the default, so PostgreSQL and Docker are not required locally. Existing Server values in the repository-root `.env.local` must be copied manually; that file remains owned by macOS development and release tooling.

Set `DAHLIA_DATABASE_TYPE=postgres` and `DAHLIA_DATABASE_URL` to move Better Auth and Gateway administration to PostgreSQL, or set `DAHLIA_AUTH_TYPE=header` for an identity-aware proxy.

For `accounts`, configure the Google OAuth callback as `http://localhost:5173/api/auth/callback/google` locally or `https://<host>/api/auth/callback/google` in production.

For an identity-aware proxy, set `DAHLIA_AUTH_TYPE=header` and `DAHLIA_AUTH_HEADER` to the verified email header. Ensure the proxy removes and replaces that header and the application server is not directly reachable.

The reference production container runs `pnpm db:migrate:prod` before starting Node, including with `header` authentication. PostgreSQL migrations use a session-level advisory lock, so replicas wait for one migrator instead of racing the same DDL. Migration metadata is kept outside the application schemas: Better Auth uses `drizzle.__dahlia_auth_migrations`, and the application baseline uses `drizzle.__dahlia_server_migrations`. Both are applied in every authentication mode, in that order.

SQLite contains user accounts, OAuth sessions, refresh tokens, and signing keys. Persist it across container replacement with a named volume:

```bash
docker build -t dahlia-server apps/server
docker volume create dahlia-server-data
docker run --mount source=dahlia-server-data,target=/app/.data \
  --env-file apps/server/.env.local -p 3000:3000 dahlia-server
```

Back up that volume when using SQLite. PostgreSQL deployments should back up the configured database instead.

## Local Cloudflare development

Cloudflare development has a separate Vite configuration so the regular `pnpm dev` Node flow remains unchanged. Put local Worker secrets in `apps/server/.dev.vars`, apply the local D1 migrations, and then start the Cloudflare Vite plugin:

```bash
pnpm db:migrate:d1:local
pnpm dev:cloudflare
```

The API Worker runs in workerd with the local D1 binding. React, JavaScript, CSS, and SPA navigations are served by Workers Static Assets without passing through Hono. Production-equivalent builds and previews use:

```bash
pnpm build:cloudflare
pnpm preview:cloudflare
```

Deployment guides:

- [Cloudflare Workers + D1 or Hyperdrive](../../deploy/cloudflare/README.md)
- [Databricks Apps](../../deploy/databricks/README.md)

## Codex 0.153.4 manual configuration

```toml
model = "<id-from-api-v1-models>"
model_provider = "dahlia-server"

[model_providers.dahlia-server]
name = "Dahlia Server"
base_url = "https://<host>/api/v1"
wire_api = "responses"

[model_providers.dahlia-server.auth]
command = "/path/to/short-lived-token-helper"
args = []
timeout_ms = 10000
refresh_interval_ms = 300000

[features]
enable_request_compression = false
```

The auth command prints a current bearer token to stdout; do not place that token in this file, an environment variable, or logs. With `accounts`, use an access token issued to `databricks-cli`. With Databricks Apps `header` authentication, use a current Databricks U2M access token. Request compression remains disabled because the service validates the uncompressed JSON body before forwarding it.

## Validation

```bash
pnpm check
```

This runs lint, TypeScript checks, unit and adapter contract tests, Node/SPA builds, and a Workers dry-run. Live credentials are tested separately with a pinned Codex 0.153.4 model-list and tool-call session and, on Databricks Apps, an SSE streaming smoke test.

## Package consumers

`@dahlia-ai/server` is versioned independently from the macOS app and published to npm from `server-v<version>` tags. Consumers should pin an exact version. Build it from `apps/server` with `pnpm build`. For active sibling-repository development, run `pnpm link ../dahlia/apps/server` from the consumer repository. To verify the exact published artifact shape, run `pnpm pack` from `apps/server` and install the resulting tarball; the `prepack` lifecycle builds the artifact automatically.

The tag workflow requires an `NPM_TOKEN` repository secret with publish access to the `@dahlia-ai/server` package.

The Worker-safe package root exports the backend extension contract from `@dahlia-ai/server`; Node-only APIs such as `createNodeAuthStore` are exported from `@dahlia-ai/server/node`. Dashboard components come from `@dahlia-ai/server/client`, shared styles from `@dahlia-ai/server/client/styles.css`, and the migration manifest from `@dahlia-ai/server/migrations`. Server migrations must run before consumer migrations. Give every SQLite and PostgreSQL Drizzle migration directory a stable lowercase ledger ID; never derive it from manifest position.

### Browser regression check for live updates

Run `pnpm dev:client` and open `/tests/browser/live-data.html` on the Vite origin. This isolated fixture renders the real App under React Strict Mode, replaces API/SSE with local fixtures, and never calls the backend. A successful run sets `document.body.dataset.testResult` to `passed` and prints `PASS` in the console. It checks thumbnail failure recovery through Retry/reconnect/online, DOM identity, tabs and scroll, empty Project rows during refresh, live sharing settings, paginated additions/deletions, reconnects, transient failures/retry, obsolete reads, failed then successful edits, search, deleted Project filter recovery, browser history, Project creation/deletion, Organization switching, canonical URL redirects, file modals and standalone previews, focus restoration, and 403/404 removal.

### Private Web detail navigation

The canonical detail URLs are `/projects/{project_id}`, `/meetings/{meeting_id}`, and
`/files/{file_id}`. Older `/vaults/{vault_id}/projects/{project_id}` and meeting URLs
replace browser history with the canonical URL. Direct loads and refreshes resolve the
owning Vault through authenticated `GET /api/v1/projects/:projectId` and
`GET /api/v1/meetings/:meetingId`. These return the existing detail representation,
including `vaultId`; missing, deleted, and inaccessible records return 404. Existing
Vault-scoped APIs remain supported.

Vault details provide Meetings, Projects, and Settings tabs; sharing and renaming live
in Settings. Project details show breadcrumbs, description, meeting count, and a meeting
list with owner-only edit/delete actions. Both support English and Japanese.

Clicking a file opens an accessible full-window preview with a dark backdrop without changing the
current URL. Escape, the close button, or the backdrop closes it and restores focus.
The top-right circular buttons toggle image information, copy the displayed image, download
the original, and close the preview. The information panel shows available capture time, format,
file size, dimensions, caption, and OCR text. Copy requires browser clipboard permission and
reports failures inline. Bottom-center controls zoom from 25% to 400%; clicking the percentage
restores the fitted view (100%). Enlarged images can be scrolled. On narrow screens the
information panel overlays the image. Modified clicks and Open in new tab (inside information)
use `/files/{file_id}`. The standalone page shares the preview controls. Supported images use the existing 1568px variant
when available; other file types offer download without embedding active content.
Live refreshes preserve current tabs, filters, loaded pages, scroll, and an open preview.

### Recording audio

New Desktop batch recordings use a dedicated API, separate from Files:

- `POST /api/v1/meetings/{meetingId}/recordings?sessionId={uuidv7}&source=mic|system`: raw `audio/mp4` with Content-Length, at most 1 GiB. New bytes return 201; identical retry returns 200; different bytes return 409. The response includes `id`, `source`, `content_type`, `size`, `checksum` (`SHA-256:<hex>`), and `contentURL`.
- `recording:upsert` in `/api/v1/transactions`: `entityId` is the internal session UUID, data contains `source`, `checksum`, and `manifest` (`sampleRate: 16000`, `frameCount`, and ranges with `startFrame`, `frameCount`, `sessionOffsetSeconds`, `localeIdentifier`). POST staging is private to the owner until this commit.
- `GET /api/v1/meetings/{meetingId}/recordings`: committed recordings in number order, up to 200 items, `nextCursor`; each item has integer `id`, `startedAt`, `endedAt`, and `audio.mic` / `audio.system`. No internal session UUID.
- `GET/HEAD /api/v1/meetings/{meetingId}/recordings/{number}/audio/{source}`: current Vault read access, byte ranges, private caching. No physical storage URL is exposed.

Numbers are allocated atomically per meeting and shared across sources of one session. Keys are `meetings/{meetingId}/recordings/audio_mic_01.m4a` and `audio_system_01.m4a` beneath the configured storage root, including Databricks Volumes. Committed audio has no retention expiry. Meeting/Vault deletion queues physical deletion; staging expires after 24 hours. Node scans all Vaults every minute, and the Worker scheduled handler uses the templates’ once-per-minute Cron Trigger, so expiration does not require subsequent Vault traffic. The scan uses paginated operational metadata and owner-scoped transactions, then drains the existing durable deletion queue. Existing Files limits remain unchanged.

Capabilities now advertise `syncVersion: 2`, `meetingEventsVersion: 1`, and `recordingAudioVersion: 1`. Upgrade Desktop before Server: old Desktop pauses sync and asks for an update. The new Desktop still supports syncVersion 1 servers without uploading recording audio.

The 1 GiB application limit does not override upstream proxy or platform request limits/timeouts. Validate the selected Node/Databricks/Worker deployment with representative long recordings before enabling source deletion; some Worker plans/proxies may reject a request below this limit. Audio recognition remains on Desktop. See [the ADR](../../docs/adr/shared/recording-audio-archive.md) for quality/release gates.

Cloudflare's [current request body limits](https://developers.cloudflare.com/workers/platform/limits/) depend on the account plan (Free/Pro: 100 MB; Business: 200 MB), so the application's 1 GiB cap is not a promise that these plans can upload 1 GiB in one POST. Staging becomes unreadable/uncommittable at 24 hours; upload and sync-change requests sweep expired metadata into the persistent deletion queue. Physical removal can wait until the next request if the deployment is idle.

Search UI regression: run `pnpm dev:client`, open `/tests/browser/search.html`, and verify `document.body.dataset.testResult === "passed"`. It uses isolated fixtures for IME, debounce, cancellation, navigation, preview, focus, refresh and Vault switching.
Summary worker diagnostics use structured `summary_job_started`, `summary_job_succeeded`, `summary_job_lease_lost`, and `summary_job_failed` events. Failure records include the generation/publish phase, bounded error code, attempt, retryability, duration, and an upstream request ID when supplied. They never include meeting content, prompts, provider response bodies, model/user/meeting identifiers, or credentials. A `summary_input_changed` failure means canonical input changed after enqueue; wait for transcript/image processing to finish, then retry. The existing summary is preserved.
