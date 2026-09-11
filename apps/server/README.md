# Dahlia Server

`apps/server` is the optional, self-hostable AI Gateway used by the Codex process embedded in Dahlia. It also provides the canonical shared data service for Dahlia Server accounts. Server Vaults and Projects are shared by Desktop and Private Web; Desktop SQLite is their offline working copy, not a one-way upload source. The service stores Vault names, Project names/descriptions/hierarchy, summaries, original transcripts, screenshots, OCR, and captions; it also stores recording archives through the dedicated recording API, but never translated transcripts or SQLite databases. Responses request content is relayed to the configured provider without being persisted or logged.

Better Auth, Gateway administration, and meeting sync share one Drizzle application database. Provider credentials remain separate runtime secrets and are never stored in that database.

## Database and Gateway configuration

PostgreSQL and Lakebase pools handle idle connection errors without terminating the server. The driver discards failed idle connections and reconnects on subsequent requests; active query errors still propagate to their callers. Diagnostics record only the `database_pool_idle_error` event, without connection or query details. Migrations retain a single connection for the entire advisory-lock lifetime and fail on disconnect rather than reconnecting without the lock.

`DAHLIA_DATABASE_TYPE` selects storage independently from authentication and the AI Gateway:

| Type | Runtime | Connection |
| --- | --- | --- |
| `sqlite` | Node | `DAHLIA_DATABASE_URL=file:...` (default: `file:.data/dahlia-auth.sqlite`) |
| `postgres` | Node or Worker | `DAHLIA_DATABASE_URL=postgresql://...` |
| `lakebase` | Node / Databricks Apps | `LAKEBASE_ENDPOINT` and injected `PG*` variables |
| `hyperdrive` | Cloudflare Worker | `HYPERDRIVE` binding |
| `d1` | Cloudflare Worker | `dahlia_db_prod` binding |

Node supports `sqlite`, `postgres`, and `lakebase`; Workers support `d1`, `hyperdrive`, and direct `postgres`. PostgreSQL-compatible connections keep generated Better Auth tables in `auth`, Dahlia-owned tables in `app`, `search`, `crypto`, and `jobs`; all schemas are owned by the connection user. Job references flow from `jobs` to `app` / `auth`; canonical references flow from `app` to `auth`. Lakebase uses the official `@databricks/lakebase` pool for OAuth credential refresh.

The 2026-09-11 prerelease baseline replaces the development migration history. Existing Server development databases (including databases already using `app`) require an explicit rebuild or a separately planned data migration; this baseline is for empty databases only. Back up needed development data and point the Server at a new empty database before running migrations. No database is reset automatically. Desktop preserves the released v0.21.0 / v41 upgrade path. The initial Server schema includes `ical_uid`, `recurrence_id`, and `calendar_event`; their unpublished incremental migrations are consolidated into it. PostgreSQL runs the Auth initial migration, application initial migration, and runtime support; SQLite/D1 run initial and runtime support.

PostgreSQL applies the unchanged generated Auth baseline, the generated application `initial` migration, then `runtime_support`. SQLite/D1 apply `initial` then `runtime_support`. The latter contains only database support SQL: PostgreSQL identity functions, generated policies (after their functions), FORCE RLS, membership indexes and deferrable transfer constraints; SQLite/D1 membership indexes, FTS5 and its maintenance triggers. Generated snapshots stay in the repository for future `pnpm db:generate` runs; the npm package ships only migration SQL. D1 SQL is copied from SQLite by `scripts/sync-d1-migrations.mjs`.

Earlier upgrade descriptions below document development history and do not provide an upgrade path from the replaced baseline. After release, migrations are immutable and changes use forward migrations.

Better Auth schemas are generated unmodified into `src/db/generated`; Dahlia tables remain in the adjacent app schema files. `pnpm db:generate-auth` refreshes the auth definitions and `pnpm db:generate` produces separate PostgreSQL auth and application streams under `drizzle/postgres-auth` and `drizzle/postgres`. Every authentication mode applies both streams in that order. Header mode keeps Better Auth endpoints disabled and projects each verified proxy identity into `auth.user`; accounts mode leaves that table under Better Auth's control. The relations-v2 adapter is used with joins disabled. SQLite and D1 retain one stream with top-level Better Auth tables, keep Dahlia table names unprefixed, and rely on the same application permission checks instead of RLS.

## API contract

The machine-readable contract is [openapi.json](openapi.json), served without authentication at `GET /openapi.json` and exported as `@dahlia-ai/server/openapi.json`. [The route audit](../../docs/architecture/server-api-audit.md) lists every Dahlia operation, previous paths, consumers, and concrete delegated Better Auth/OAuth/MCP operations. [The ADR](../../docs/adr/server/openapi.md) records the coordinated breaking update.

Run `pnpm openapi:generate` without DB credentials to regenerate the OpenAPI 3.1 spec, Web types/calls and audit. `pnpm openapi:check` verifies deterministic outputs and the independent route inventory; it is part of `pnpm check`. The Desktop DahliaServerAPI SwiftPM target generates Apple clients from the same file. Do not edit generated TypeScript or Swift files. Desktop CI also starts `tests/openapi-fixture.ts` with disposable SQLite and object storage, then runs `OpenAPIIntegrationTests` with `DAHLIA_OPENAPI_TEST_URL` set to its loopback endpoint. This verifies exact Transaction replay/nulls, RFC 3339 dates, streamed file bytes, and SSE reconnection through the generated Swift client.

Dahlia-owned APIs use camelCase JSON and RFC 3339 timestamps; nullable PATCH values clear fields and omitted fields are retained. Collection ends are `nextCursor: null`; admin directories retain `offset` and `hasMore`. Ranked search and sync feeds retain their purpose-specific envelopes. Invalid/unknown JSON fields, duplicate single query parameters, numeric bounds and Content-Type are rejected. The OpenAPI contract keeps explicit success responses and one `default` Problem response per operation, without synthesizing examples. Entity ID schemas are projected from the same TypeID field mapping as the HTTP transport, including UUIDv7 version and variant requirements; internal Zod validation remains UUID-based. Repeated metadata uses shared schema references; common authentication is inherited from document-level security, with explicit overrides for public and browser-only operations. Error HTTP statuses, headers and conflict payloads remain unchanged; clients use the actual HTTP status and `code`. Errors use RFC 9457 `application/problem+json` with `code` and optional conflict data. OAuth, Better Auth, Gateway and MCP retain their native formats.

File upload is `POST /api/v1/file-uploads` with `{ id, vaultId, name, contentType, metadata }`, then `PUT /api/v1/file-uploads/{fileId}/content` with `application/octet-stream`, Content-Length and raw bytes. The reserved contentType is authoritative. Staging stays private until Transaction commit. Read JSON at `/files/{fileId}`, original bytes at `/files/{fileId}/content`, variants at `/files/{fileId}/variants/{variant}`. Internal storage URI and offset are not exposed.

Meeting and Project detail reads are unscoped (`/meetings/{meetingId}`, `/projects/{projectId}`); Vault paths are for collections. Summary/transcript history is `/meetings/{meetingId}/summaries` or `/transcripts`, with `/latest` and `/{version}` reads. Transcript chunks stage at `/meetings/{meetingId}/transcript-uploads/{patchId}/chunks/{chunkIndex}`. Start summaries at `POST /meetings/{meetingId}/summary-jobs`; `202 Location` points at the individual job. `GET /summary-jobs/latest` is separate; cancel/retry are POST actions on an individual job. Requests use `detail` and `outputLanguage`; queued jobs retain their captured settings.


| Path | `accounts` | `header` |
| --- | --- | --- |
| `/`, `/sign-in`, `/dashboard/**`, `/vaults/**` | Static SPA | Static SPA |
| `/organizations` | Joined organizations and invitations; create an organization in a modal | Joined organizations |
| `/organizations/{slug}` | Members, Teams, and Settings tabs | Default organization Members, Teams, and Settings tabs |
| `/accept-invitation/**` | Better Auth invitation management | Not used |
| `/api/auth/**` | Google sign-in and OAuth 2.1 endpoints | Disabled |
| `/api/v1/session` | Account session and capabilities | Validated email-header identity and capabilities |
| `/api/v1/admin/**` | Platform administrators only | Platform administrators only |
| `/api/v1/models` | Dahlia OAuth with `all-apis` | Platform U2M / proxy authentication |
| `/api/v1/responses` | Dahlia OAuth with `all-apis` | Platform U2M / proxy authentication |
| `/api/v1/vaults/**` | Browser session or Dahlia OAuth with `all-apis` | Proxy identity |
| `GET /api/v1/organizations` | Browser session or Dahlia OAuth with `all-apis`; current memberships only | Current memberships for proxy identity |
| `POST /mcp` | Dahlia OAuth with `mcp` or `mcp:read` | Databricks Apps / trusted proxy identity |
| `/healthz` | Minimal liveness | Internal liveness; anonymous external access is not guaranteed |

`accounts` is the default authentication. It serves OAuth/OIDC discovery under `/.well-known/**`. Both hosted and self-hosted deployments use the fixed public client `databricks-cli`; it requires authorization code with S256 PKCE and supports rotating refresh tokens and revocation. Its default redirect allowlist retains the released `http://127.0.0.1:1455/oauth/callback` and also accepts the Desktop callback `http://localhost:8020`. RFC 7591 dynamic client registration remains disabled. Node deployments support MCP 2026-07-28 Client ID Metadata Documents (CIMD) with pinned public-address fetching; the MCP resource is `${DAHLIA_APP_URL}/mcp` and its protected-resource metadata is at `/.well-known/oauth-protected-resource/mcp`.

OAuth access from Dahlia Desktop uses the single `all-apis` capability scope for models, Responses, synchronization, deltas, and events. OIDC identity scopes remain separate protocol scopes.

### HTTP conventions

Dahlia-owned and registered extension API paths return `405` with `Allow` for unsupported methods; matching route patterns contribute all their allowed methods. Unknown paths return `404` after applicable authentication. Disabled features retain their existing non-disclosure behavior. Better Auth and explicit extension fallbacks keep their own contracts. Errors retain the machine-readable `error` code and transaction conflict details; HTTP preconditions use `412`, domain revision conflicts use `409`.

| Operation | Authentication | Success | Pagination / retry |
| --- | --- | --- | --- |
| Canonical reads, capabilities | Browser session or `all-apis` | 200 | Paged lists return `nextCursor`; follow until absent/null |
| `POST /api/v1/transactions` and `/transactions/resolve` | Browser session or `all-apis` | 200 receipt | Retry/resolve with the same ID and body; never advance the pull checkpoint from a receipt |
| `POST /api/v1/file-uploads`, then `PUT /file-uploads/{id}/content`; recording PUT staging | Browser session or `all-apis` | 201 new upload, 200 identical retry | Same ID and bytes; a different payload is 409 |
| `PATCH /api/v1/files/{id}` | Owner browser session or `all-apis` | 200 metadata | Preserve omitted keys; reconcile a 409 before retrying |
| File and audio GET / HEAD | Current Vault access | 200, 206 GET range, 304 revalidation | 412 requires revalidation; do not append partial bytes after a full 200 |
| Summary generation POST | Owner browser session or `all-apis` | 202 with job Location | Poll the job; canonical results arrive through deltas |

Cookie-authenticated mutations retain Origin checks. Invalid input is 400/411/413/415/422, authentication/authorization errors are 401/403 or permission-hiding 404, and expired sync cursors are 410. Automatic retries are limited to transport failures, 408, 425, 429 and 5xx. Files PATCH is not a replayable transaction receipt API; Desktop keeps its durable transaction queue.

The transaction endpoints, POST cross-Vault search versus GET exhaustive Vault search, binary Files versus JSON metadata, and direct-ID versus Vault-scoped reads are intentional. Their existing response field names and envelopes remain unchanged.

### Meeting sync and Vault sharing

Server-account Vault changes propagate bidirectionally between Desktop and Private Web through the selected Dahlia account connection; pausing synchronization does not turn the Server record into a secondary copy. Local accounts remain device-local and create no sync transactions. Desktop API calls require `all-apis`; Server MCP reads require `mcp:read`. `app.vault_permissions` is the permission source of truth: every Vault has one immutable `user` owner identified by the authentication provider's raw user ID, while optional `user`, `organization`, and `team` members are read-only. PostgreSQL/Lakebase RLS and the SQLite/D1 store resolve access through the Vault permission. Transcripts inherit that access through their meeting, and transcript segments through their transcript. Files belong to a Vault independently of their `meeting_attachments` associations; deleting an association or meeting preserves the file. Original keys are `files/{fileId}/original`, independent of the Vault and meeting.

Meeting metadata includes nullable `icalUid` and `recurrenceId` (`meetings.ical_uid` / `recurrence_id`). Match the pair to correlate participants' records; the index is non-unique and does not merge meetings or grant access to other Vaults. RECURRENCE-ID uses the original occurrence date/time, even after rescheduling: UTC `YYYYMMDDTHHMMSSZ`, all-day `YYYYMMDD`, or an empty string for a single event. Missing identity is null. Both fields must be provided together; omission preserves existing values on updates and explicit nulls clear both. Desktop sends its existing calendar key with meeting creates/updates when available. Calendar titles/descriptions and local calendar references remain device-local; editing on a device without that calendar preserves Server identity. Existing Server rows start with nulls and acquire the key on the next metadata write from a linked Desktop meeting. The identity columns remain queryable metadata, including for encrypted Vaults. `calendarEvent` stores only `{ start, end, is_all_day }` in `meetings.calendar_event` (PostgreSQL JSONB; SQLite/D1 JSON text). Desktop serializes the start/end instants and all-day flag already in its local calendar record, without correcting dates or converting all-day events to date-only values. The Server rejects snapshots whose end precedes their start; equal instants are valid. The IDs are not duplicated inside the JSON. The snapshot is queryable metadata, including for encrypted Vaults; omitted updates preserve it, and explicit null clears it. Existing rows have a null snapshot until a linked Desktop meeting sends metadata. Desktop keeps the canonical calendar values separately from device-local references so later metadata updates cannot restore a remotely cleared or changed value. Observed start/end/all-day changes enqueue updates for linked writable Server meetings atomically; Local and member Vaults do not upload these changes.

Desktop and Private Web mutations use `POST /api/v1/transactions`. Each transaction uses a `txn_` TypeID backed by UUIDv7 and is limited to one Vault, committed atomically, and replay-safe by transaction ID. Vault, Project, meeting metadata, and summary writes require the current canonical revision; conflicts return `409` with the Server record. File content and transcript chunks remain bounded staging uploads and are activated by a transaction. Sync schema version 2 replaces the screenshot entity with `file` and `meeting_attachment`; roll out Desktop, Web, and Server together.

Desktop keeps immutable operations until the Server receipt is applied. File operations include the staged content checksum (`SHA-256:` plus lowercase hex); transcript operations use `transcript:patch` with per-chunk hashes and explicit segment upserts/deletes. `400`/`411`/`413`/`415`/`422` stop as validation errors, `409` stops as a revision conflict, `401`/`403` stop as authorization errors after one token refresh, and only transport errors, `408`, `425`, `429`, and `5xx` retry automatically. The transaction response cursor records the last local commit; it never advances the separate delta pull checkpoint.

`GET /api/v1/vaults/{vaultId}/changes?cursor=...` is the durable delta feed. The first page returns a `highWaterCursor`; clients pass it on later pages so each bounded catch-up returns one final canonical state per changed entity through a stable boundary. `GET /api/v1/events` sends only SSE invalidations and opaque cursors; clients always fetch canonical data from the delta/read APIs and can catch up after disconnect or application shutdown. Server MCP remains read-only.

Vault and Project operations are committed through the domain transaction endpoint before meeting data. Projects are available for hierarchy browsing and meeting filtering but are not added to full-text or vector search. Transcript segments keep `audioSource` (`mic` or `system`) separate from nullable `speakerLabel`, which is reserved for future diarization.

Restoring a Vault after a reset with `preservePermissions: true` remains owner-only. A non-owner cannot restore a revision-0 Vault: an owner-scoped restoration update that affects no rows, or an ownership check for a Vault hidden by PostgreSQL/Lakebase RLS, returns `404 vault_not_found` without canonical content. The entire transaction is rolled back, including subsequent Project/Meeting operations, change history, and the receipt. Owners retain normal restoration and idempotent retry behavior.

### Server capabilities

`GET /api/v1/capabilities` requires the existing browser authentication or `all-apis` scope and returns supported feature versions:

```json
{
  "sync": { "version": 4 },
  "recordingArchive": { "version": 1 },
  "meetingEvents": { "version": 1 },
  "search": { "version": 1 },
  "imageAnalysis": { "version": 1 },
  "meetingSummaryGeneration": { "version": 2, "sources": ["transcript", "audio"] }
}
```

`sync: { version: 4 }` requires body-free snapshot/delta responses and file text hydration through individual JSON metadata, and includes recording archive metadata in the synchronization contract described here: atomic transactions (transaction schema version 2), snapshot/delta recovery and receipt resolution, metadata-only reads, and separately hydrated text bodies. `meetingEvents: { version: 1 }` advertises the meeting-event acceptance contract described below. Feature versions are independent of entity revisions and payload schema versions. Desktop requires sync.version 4 for sync. It independently enables events and recording uploads when meetingEvents.version and recordingArchive.version respectively advertise 1, and ignores unknown fields.

Every supported feature is an object with its own contract `version`; `recordingArchive` covers upload, storage, and retrieval of recorded audio. Unsupported features are omitted, never represented by `false` or version 0. Stores without atomic sync support none of these features and return `200 {}`; lack of a feature does not make the capabilities endpoint unavailable. Authentication and operational errors still return errors. Roll out Server and Desktop together; legacy flat version fields, boolean image analysis, and `summaryGeneration` are not supported. The old `/api/v1/sync-content` route remains unavailable.

### Partial text reads

Full transcript replacements keep one atomic publication even above 50,000 segments: Desktop stages bounded chunks and Server consumes them one at a time inside the commit transaction. The 500-item chunk bounds, Desktop's 6 MiB encoded chunk limit, and the 8 MiB HTTP request limit remain; incremental append patches retain the 50,000-item / 100-chunk limits. A missing or invalid chunk rolls back the entire new version. Desktop retains a stale body's generation descriptor until hydration publishes the new body and descriptor together, so offline reads and edits never use a newer version's model metadata with older text.

The transcript-version upgrade backfills existing bodies, including previously published empty transcripts, into version 1 before enforcing the parent foreign key. The initial parent reuses the meeting UUID and preserves its transcript sync revision; segment IDs, text, utterance timestamps and speaker/source fields remain unchanged. Unrecorded generation metadata and lifecycle times remain unknown. SQLite/D1 rebuild parent and child tables together to prevent cascade deletion with foreign keys enabled; PostgreSQL restores FORCE RLS before the migration transaction finishes. Released migrations preceding this upgrade remain unchanged.

Desktop requires `sync: { version: 4 }` before synchronization. Unsupported or missing capabilities produce an update-required state while preserving local bodies and stopping synchronization and eviction. Transaction schema version 2 is unchanged.

Snapshot and changes always omit transcript bodies, summary documents (including meeting/search duplicates), OCR and caption. Canonical IDs, revisions, ordinary attributes, relationships, deletions, body presence and transcript counts remain available. The content query switch and contentMode response field are removed. Meeting detail reads also return metadata, including `summaryRevision`, `contentOmitted` and `hasSummary`, without `summaryTitle`, `summaryDocument` or `summaryCreatedAt`. Text hydration does not advance sync cursors; persistent content state tracks missing/stale bodies independently and permits retry after failure or restart.

`GET /api/v1/meetings/{meetingId}/transcripts` lists transcript versions newest first with cursor pagination. `/transcripts/latest` and `/transcripts/{version}` read the full body for that version; `?manifest=1` returns its manifest. The envelope is `{ formatVersion: 1, version, syncRevision, transcript, entity, entityId, present, count, byteCount, sha256 }`. `version` identifies history; `syncRevision` identifies synchronization state. Body pages include `items` and `nextCursor`, contain at most 500 segments, and target 6 MiB. Every page rechecks Vault access. Clients must match version and syncRevision across pages, retrying a changed live/latest read. Versions with a confirmed generation end and all versions superseded by a newer version have immutable bodies. Summary hydration uses the existing meeting `summaries/latest` API.

Transcript mutations carry `transcript: { id, startedAt, endedAt, metadata }` and `mode: "replace" | "append"` alongside the chunk manifest. A replacement publishes a full snapshot atomically. Live recording allocates one version at start, copies the preceding body once only for the same provider/model, appends confirmed segments, and records `endedAt` only when generation termination is confirmed, including explicit cancellation. Recovery after an unobserved termination leaves it null. Empty lifecycle writes are valid. Transaction retries retain the generation ID. Server `transcripts` has a UUID primary key, `meeting_id` foreign key, and unique `(meeting_id, version)`; it has no `vault_id`. Segments use `(transcript_id, segment_id)` as their primary key and only `transcript_id` as their foreign key. Authorization follows segment → transcript → meeting → Vault. Meeting/Vault deletion cascades through all versions. Sync ledger pruning does not prune transcript history.

`transcripts.started_at` is this version's generation start, `ended_at` is its confirmed generation end (not a success result), and `created_at` is its first Server save time; subsequent writes preserve `created_at`. Segment `started_at` / `ended_at` remain absolute speech timestamps. Batch recognition adds the audio range offset and recognition-relative seconds to the original recording start, so processing yesterday's recording today still retains yesterday's speech timestamps. Segment `created_at` is the source's absolute creation time for the confirmed text, recorded for both live and batch generation. Copying to another version and retries preserve it; retranscription creates new segments and creation times. Wire segment fields are `{ segmentId, startedAt, endedAt, createdAt, text, audioSource, speakerLabel }`. Unconfirmed text is excluded before persistence; there is no stored `is_confirmed`.

`status` is calculated on reads, never stored: a non-null `ended_at` yields `ended`; otherwise the maximum known child `created_at` yields `active` through the five-minute boundary (inclusive) and `inactive` after it. No known creation time yields `unknown`. Reads also expose `latestSegmentCreatedAt` so clients can recalculate without fetching the body. The shared [TranscriptPolicy.json](../desktop/Sources/DahliaRuntimeSupport/Resources/TranscriptPolicy.json) defines the five-minute window once for Server, Web, and Desktop. It tolerates ordinary pauses and delayed delivery; these are activity estimates, not evidence of connectivity, continued recording, silence, or a crash. History endpoints use `Cache-Control: no-store`; Private Web omits activity status from its transcript toolbar, and Desktop computes status when read.

Desktop's forward migration preserves absolute speech times, recording/session associations, body text, and pending operation IDs/payloads. Historical segment creation times use the agreed meeting-end proxy: the latest recording-session end, or recording start plus duration if no session end exists. An unended session or unavailable meeting end leaves it null. This proxy is not represented as an observed generation time. New segments always record actual source creation time. Old `completedAt` / `savedAt` descriptor fields are renamed and persisted status is removed; migration does not invent a generation end.

Desktop retains only the latest body and descriptor. Same-model batch additions process the new audio and publish the combined body as a new version. Explicit retranscription or a model change requires all meeting audio and commits only after every recording succeeds. Missing retained audio, failure, or cancellation preserves the previous body. Metadata records provider/model and generation runs (execution host, audio input, language, timestamps, and optional response model/ID/token usage). Legacy Desktop rows retain their body with unknown provenance. Gemini execution is not included; the metadata contract can represent future Server generation.

`GET /api/v1/files/{fileId}` always returns JSON file information with `revision` and `metadata.ocrText` / `metadata.caption` (nullable). Desktop checks ID, Vault, checksum and the synchronized revision, then rechecks local edit protection before installing the body. A changed revision triggers normal sync and one retry; stale responses never update confirmed metadata or overwrite local edits. The unused `text/file` route is removed without a fallback. Dependency reconciliation observes only the metadata projection; body completion belongs to the content provider.

`HEAD /api/v1/files/{fileId}/content` uses the same authorization and storage adapters as GET, reports the binary representation's Content-Type, Content-Length and ETag, ignores Range, and sends no body. Local storage uses stat, R2 uses head, and S3/Volume use upstream HEAD. Application JSON metadata stays in the JSON endpoint. GET continues to stream the original file.

SHA-256 framing is UTF-8 `decimalByteLength:bytes` per field, with `-:` for null. Transcript input is lowercase segment UUID then text in startedAt/UUID order; only text contributes to byteCount. Summary input is one nullable document; file input is nullable OCR then caption. [Shared fixtures](../../test-fixtures/text-content-v1.json) test Swift/Server agreement. Clients validate both page and complete manifest for summary/transcript before installing downloaded text. File metadata is a single revision-bound response; Desktop computes the local retention fingerprint from its nullable OCR and caption.

`POST /api/v1/vaults/{vaultId}/text-search` with JSON `{ query, kind, limit?, cursor? }` provides exhaustive FTS pages, without the Hybrid candidate cap. Results are `{ version: 1, scope: "server", items: [{ id, meetingId, snippet }], nextCursor }`; limit is 1–200 and snippets are at most 180 characters. Cursor identity includes Vault, query, kind and current ledger revision. A 409 invalidates the search cursor. Clients apply local filters before concluding enumeration and report incomplete/offline coverage explicitly; search does not download full text for retention.

### Sync history retention and recovery

The change ledger is sync-only and guarantees 90 days of delta recovery. `app.sync_vault_state` retains the latest sequence and the pruned boundary even when every change has been deleted. Every delta page checks that boundary and returns `410 sync_cursor_expired` for an expired cursor.

New devices and expired clients use `GET /api/v1/vaults/{vaultId}/snapshot`. It returns `{ items, startCursor, nextCursor }`, with at most 100 canonical `{ entity, id, revision, record }` items ordered by entity and ID. Item serialization is capped at 8 MiB per page (plus envelope overhead); a single larger record is returned alone to guarantee progress. Records are loaded incrementally, including at most one look-ahead record. Pass `nextCursor` as `cursor` and preserve `startCursor` on subsequent pages. Fetch existing transcript and screenshot endpoints for their bodies. After enumeration, fetch delta pages from `startCursor` with a fixed high-water boundary and merge their changes/deletions before removing absent local records. A `410` during enumeration or catch-up requires a fresh snapshot. Each page reauthorizes current Vault access; this is not a transaction held open across requests.

`POST /api/v1/transactions/resolve` accepts exactly the same body as the commit endpoint. It validates and normalizes the request and compares its hash without mutation or upload staging. Responses are `{ id, status: "unknown" }`, the original committed response, or `{ id, status: "committed", receipt: "compact", cursor, records: [{ entity, id, revision }] }`. Different content with the same ID remains `409 idempotency_key_reused`; another user cannot resolve the receipt. Resolve before restaging/retrying. An unknown result must keep the original ID, body and base revisions. Compact results acknowledge the queued operations, preserve later local edits, and require a canonical refresh without advancing the pull checkpoint to the receipt cursor. The legacy commit endpoint returns `410 transaction_receipt_expired` instead of passing a compact result off as an ordinary receipt.

### Meeting events and recording indicators

`meeting_events` is Server-only domain history, separate from the 90-day synchronization ledger. Server records `meeting_created`, `meeting_updated` (changed field names only), and `meeting_deleted` atomically with accepted meeting mutations. Desktop sends `tag_added`, `tag_removed`, `recording_started`, `recording_ended`, and `segment_rotated` through `meeting_event:create` transaction operations, with `baseRevision: null` and the event UUID as `entityId`. Event data contains `meetingId`, `kind`, `occurredAt`, and only the relevant `sessionId`, `relatedId` (local numeric tag ID or segment UUID), `audioSource` (`mic` / `system`), and positive `segmentIndex`. Tag names, field values, audio, and file paths are never included. A segment rotation means switching to the next physical segment, not successful finalization; initial file creation is not a rotation.

`GET /api/v1/capabilities` advertises `meetingEvents: { version: 1 }`. Desktop queues events only after confirming this capability for the current Server Vault, rechecks before upload, and omits diagnostic uploads if the Server has been downgraded. Unsupported and Local accounts do not record events. Normal transactions and event IDs are independently idempotent; different content with an existing event ID is rejected. Owner authorization and session-to-meeting relationships are checked before accepting events. This is a diagnostic history of accepted operations, not a tamper-proof audit trail or telemetry.

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

The Private Web sidebar displays collapsible Projects and their meetings, with dates and the current meeting highlighted. Hovering or keyboard-focusing a meeting shows a detail panel to its right with the title, duration (or recording status), Project, date, and description; Escape dismisses it. Project rows use the same hover/focus panel to show their name, meeting count, and description. Only the selected Vault’s Projects and meetings appear in the sidebar, without a Vault-name heading; switch Vaults from the account menu. Meetings without a Project remain accessible under **Unassigned**. **New Vault** remains available while an Organization is selected. Creation keeps personal ownership and switches to Personal scope to open the new Vault; owners can then share it from its detail page. Vault routes determine the selection; other pages restore the last selection per user and Personal/Organization scope from tab-scoped session storage, defaulting to the first available Vault. Expand controls are separate from detail links; meetings load on expansion, with **Show more** for subsequent pages. The sidebar footer shows the account name and current Vault (or Personal/Organization scope). Its compact account menu uses icons and separate Vault and Organization sections; the current Vault has a checkmark and each Vault links to its details. The account row opens account information. The remaining entries provide Personal/Organization switching, Vault and Organization management, account settings and capability-gated extension links. **Members** appears inside the **Organizations** section for platform administrators, including deployments without sharing. Session-authenticated accounts can sign out from the bottom of the menu; sign-out errors stay visible for retry. Proxy-authenticated deployments omit sign-out because their identity is managed upstream. Selection and expansion are stored per user in tab-scoped session storage. The initial selection is Personal; a revoked Organization selection returns to Personal.


Built-in dashboard links update the main area through browser history without reloading the document. The sidebar retains its loaded Project/meeting lists, expansion state, and scroll position; selection highlights and the selected Project ancestry update in place. Back/Forward follow the same path, and each main page starts with fresh detail state. Keyboard focus moves to the new content without outlining the whole page; interactive controls retain their focus indicators. Modified clicks, downloads, authentication, and unregistered routes retain normal browser navigation; registered extension routes use SPA navigation. Account and permission writes refresh the shared account menu and session capabilities, including Organization/Team membership, Vault sharing, and administrator changes. Sync transactions refresh canonical data without re-fetching the session. Read requests and failed writes do not trigger this refresh. Transactions notify once, only after validating a committed receipt from the initial request, resolution, or retry; unknown resolution results and invalid receipts do not refresh projections. Protected API responses with status `401` return to sign-in with the current path; `403` authorization failures and `409` conflicts remain page errors.

SSE connection/reconnection and invalidation notifications, and validated sync transaction receipts, refresh mounted data consumers without reloading the document. Reads are coalesced to one active request and one trailing refresh per consumer. Background refreshes retain the selected meeting tab, sidebar expansion, scroll position, search filters, and loaded list range. Lists re-read from the first page through the loaded item count using fresh cursors; unchanged records keep their references. Transient failures retain content with a Retry action, while 401/403/404 clear the affected data. Navigation aborts obsolete reads; changing user or Organization clears the previous scope. SSE cursors are reconnect hints, never persisted as completed data checkpoints; reconnect and coming back online re-fetch current data. Editing, creation/deletion, and Organization switching use the same data refresh and History API navigation paths. A different meeting still starts on Summary.

Project lists show only the Project name/path and meeting count, without descriptions. Meeting lists show compact single-line rows with the meeting name, recording indicator, date, and duration; summary/description previews are omitted. The meeting detail header and body appear only once meeting and Vault data are available, without flashing a placeholder title or loading document; read failures retain their error and Retry action. Meeting details follow the desktop document layout: title, date/duration, Project and summary tags above **Summary**, **Screenshots**, and **Transcript** tabs. Project names load independently, so a failed name lookup does not hide meeting content or its Project link. Meeting descriptions are available in the sidebar preview and a collapsed Description disclosure on the detail page, including for read-only members using touch or keyboard. Summary and transcript version pickers sit at the upper left with an inline Version label and compact spacing. Dropdown menus align their left edge with the trigger and stay within the viewport. Summaries retain their headings, lists, tables, line breaks, and timestamp labels. Transcript rows use compact text and spacing, subtle separators, and speaker badges. They show elapsed `HH:mm:ss` from the recording start, falling back to the first transcript segment when the recording start is absent, as Desktop does without session timing. The current Server transcript contract does not expose recording-session timing, so resumed-session pause offsets cannot be applied. **Actions** contains only owner-only meeting metadata editing. Private Web does not offer manual summary creation, editing, or deletion; read-only members do not see those controls. Recording, notes, and conversation analysis controls are omitted because these features are not available in Private Web. New meeting and navigation labels use Japanese for Japanese browser locales and English otherwise.

`GET /api/v1/vaults` returns every Vault the authenticated user can read, including owned Vaults and direct-user, Organization, and Team shares. Optional `owner=user_…` filters this accessible set by the owning user; another user's ID is allowed but never exposes unreadable Vaults. Owners are currently users only, so `org_…`, `team_…`, raw UUIDs, and malformed IDs are rejected. The mutually exclusive `organizationId=org_…` filter still means shared **to** that Organization or one of the user's Teams within it, not owned by the Organization. It requires current Organization membership (`403` otherwise). Multiple matching grants return one row; invalid or simultaneous filters return `400`.

**Client compatibility:** `userId` and `scope=accessible` are removed. Desktop discovery uses the unfiltered list. Web personal lists and transfer candidates explicitly pass the signed-in user's `owner`; update Server and clients together. `GET /api/v1/organizations` lists the authenticated user's Organizations in both accounts and header modes and accepts browser or `all-apis` gateway authentication.


Files API storage currently requires the Databricks Volume backend. Reserve a client-generated `file_` TypeID backed by UUIDv7 and attributes using JSON, then stream immutable bytes by PUT. `name` is 1–255 characters, `metadata.source` is `upload` or `screenshot`, and optional dimensions are positive integers up to 33,554,432. OCR and captions belong in later metadata mutations. PUT requires Content-Length up to 64 MiB and application/octet-stream; the MIME type comes from the reservation. Server computes size and SHA-256 while streaming. A missing length returns 411, an excessive length 413, and unsupported encoding 415.

```http
POST /api/v1/file-uploads
Content-Type: application/json

{"id":"<file_TypeID>","vaultId":"<vlt_TypeID>","name":"capture.png","contentType":"image/png","metadata":{"source":"screenshot","width":1800,"height":900}}
```

```http
PUT /api/v1/file-uploads/{fileId}/content
Content-Type: application/octet-stream
Content-Length: 12345

<raw PNG bytes>
```

The response contains file metadata, including the computed `size` and `checksum`, `contentUrl`, and available `variants`. A completed new upload returns `201`; retrying an uploaded ID with identical bytes, MIME type, and source returns `200` without changing its bytes, name, or metadata. Different content for an uploaded ID returns `409`. Failed uploads remain retryable; partial storage objects are removed, with failed removals retried by the storage deletion queue. Node SQLite serializes storage mutations across instances using an adjacent `.storage-lock` SQLite file; this does not lock the application database during network I/O. Keep that lock file in place while any instance is running. PostgreSQL uses per-key advisory locks for concurrent storage workloads. The canonical `uri` is the full `/Volumes/{catalog}/{schema}/{volume}/files/{fileId}/original` path. Device-local paths never cross this API. The former single POST with query attributes is removed; update Server and Desktop together.

Uploads remain private staging until a revision-checked `file:upsert` commits through `/api/v1/transactions`; its checksum must match the Server result and its `metadata` patch preserves other keys. Replacing bytes requires a new file ID. Unpublished uploads expire after 24 hours and can be uploaded again. `meeting_attachment:upsert` associates an existing canonical file and meeting in the same Vault, with an independent association ID, nullable `capturedAt` and `sessionId`, and `createdAt`. A file may be attached to multiple meetings. `meeting_attachment:delete` only unlinks; `file:delete` rejects remaining associations, which may be removed earlier in the same atomic transaction.

`PATCH /api/v1/files/{fileId}` update metadata on an owner's committed file with a JSON body containing required `baseRevision` and `metadata`. Allowed metadata keys are `width`, `height`, `ocrText` (up to 20,000 characters), and `caption` (up to 500 characters). Omitted keys are preserved; `null` clears OCR or caption. `source`, bytes, `size`, and `checksum` cannot be changed. Invalid fields return `400`, missing/staged files and non-owner access return `404`, and stale revisions return `409` with the canonical conflict record. Success returns `200` with the committed file metadata, content URL, variants, and new revision. Metadata mutations share the transaction, search, and delta machinery of Desktop metadata updates; clients receiving a conflict refetch/reconcile before retrying.

```http
PATCH /api/v1/files/{fileId}
Content-Type: application/json

{"baseRevision":3,"metadata":{"ocrText":"Recognized text","caption":"Quarterly revenue"}}
```

`GET /api/v1/files/{fileId}` returns canonical metadata, a content URL, and available named variants. File lists include the same content URL and variants. `GET /api/v1/vaults/{vaultId}/files` and `GET /api/v1/meetings/{meetingId}/files` return at most 200 rows ordered by ID, with `nextCursor` for the next page. Pending files are excluded. MCP `get_meeting_screenshots` reads the screenshot projection and retains chronological pagination and bounded search.

`GET` / `HEAD /api/v1/files/{fileId}/content` reads the original and supports byte ranges. HEAD returns size, MIME type, ETag, and other read headers without a body. The former metadata suffix and binary GET at the file ID itself are removed. `/api/v1/files/{fileId}/variants/{variant}` supports `thumb_480` (480px, grid), `thumb_1280` (1280px), `thumb_1568` (1568px, preview), and `thumb_1920` (1920px). All sizes are long-edge limits. Variants preserve aspect ratio without upscaling and generate quality-80 WebP on first request, persisted at `files/{fileId}/variants/v1/{variant}.webp`, and reused across restarts. Generation uses the existing Node `sharp` dependency, coalesces requests, and is bounded to two active jobs and 32 queued/active jobs. Storage failure fails the request so it can retry; the variant endpoint never substitutes original bytes. Runtimes without a transformer advertise no variants. Every metadata, original, and variant read uses current Vault permissions. Original and variant ETags distinguish the recipe version. Responses use `Cache-Control: private, no-cache`: clients may store bytes but must revalidate before reuse so each reuse checks current Vault access. Authorized GET and HEAD requests evaluate the public ETag and dates in HTTP precondition order: If-Match (strong comparison, failure 412), otherwise If-Unmodified-Since; then If-None-Match (weak comparison, match 304), otherwise If-Modified-Since. Matching ETag validation avoids storage access unless an earlier date precondition requires HEAD. GET Range is applied only after these checks; If-Range must match a strong ETag or an exact Last-Modified date outside the 60-second ambiguity window, otherwise the full representation is returned with 200. HEAD ignores Range and reports the full size without a body. Unknown range units are ignored. Metadata is rechecked against the response-header snapshot before storage access to reject a file ID replaced between those lookups. `Vary: Authorization, Cookie` separates credential-dependent browser cache entries. Storage error responses use `no-store`. Current Vault access and variant availability are checked before revalidation, so deleted or inaccessible files still return `404`. Package-root imports remain Worker-safe.

Web screenshot grids use `thumb_480`, open `thumb_1568`, and offer an original link. Unsupported transformers advertise no variants; generation failures are shown rather than silently replaced by original images. `MeetingSyncService.readFileContent(identity, fileId, variant)` shares authorized generation and cached streaming reads with server-side consumers; HTTP delivery adds response headers separately. The unpublished `thumbnail` name is removed and returns 404.

`GET /api/v1/meetings/{meetingId}/transcripts` returns up to 10,000 segments in chronological order. Pass `nextCursor` as `cursor` to continue; MCP `get_meeting_transcript` uses the same page contract.

Explicit Organization, Team, and direct User sharing is always available. Only owners can grant or revoke access; shared members have read-only access.

In accounts mode, owners use Better Auth Organizations, invitations, and Teams. In header mode, every validated proxy user is projected into `Default Organization` (ID / slug: `external`); the first user is its immutable owner. No default Team is created. Organization owners manage Team membership from the same Web page. Vault owners explicitly grant read-only access through `PUT|DELETE /api/v1/vaults/{vaultId}/permissions/organizations/{organizationId}`, `/permissions/teams/{teamId}`, or `/permissions/users/{userId}`. PostgreSQL/Lakebase always migrate the generated `auth` baseline before the application baseline. RLS receives only transaction-local `app.user_id` and resolves current membership from `auth.member` and `auth.team_member`.

The exhaustive `/api/v1/vaults/{vaultId}/search` endpoint orders by document ID. This keeps its pages stable when writes to another Vault change corpus-wide relevance scores.

### Common search API

`POST /api/v1/search` and the read-only MCP `search` tool share the same request and result order. The authenticated JSON body requires `vaultId`; optional fields are `query` (default empty; trim, then at most 500 UTF-16 code units), `kind` (`meeting`, `screenshot`, `project`; omitted means all), `projectId` (including descendants), timezone-qualified `from`/`to` (inclusive/exclusive), and `limit` (per kind, default 50, range 1–100). Unknown fields, non-string queries, invalid dates and reversed ranges return 400; bodies over 16 KiB return 413. No `q` alias is accepted. Empty queries return recent items. Meeting dates are creation dates, screenshot dates are capture dates; date-filtered projects must have a meeting in the selected period, including descendants.

The response is `{ vaultId, meetings, screenshots, projects, limited: { meeting, screenshot, project } }`. Each hit has `id`, `kind`, `title`, ISO `date`, `snippet`, and applicable `meetingId`, `projectId`, `projectPath`, `fileId`, or `meetingCount`. Arrays preserve relevance order, are bounded to 100 per kind, and expose no scores, vectors or cursor. A `limited` flag means the selected cap was reached; refine filters rather than treating this as exhaustive enumeration. Responses use `Cache-Control: no-store`; search input is never logged. Permission and project/date filters are applied before FTS/vector candidate limits, query embedding is shared once across kinds, and current Vault access is rechecked before returning. Projects match normalized name/path terms and sort by recent meeting activity.

Capabilities advertise `search: { version: 1 }`. Desktop Server accounts use these ranks without hydrating retained-out bodies; pending local meetings, images and projects have separate sections. Offline, older servers, unsynchronized metadata, tag filters and multiple selected projects use explicitly labeled device-only search. Local accounts retain existing search. The legacy GET search endpoint above keeps exhaustive FTS/cursor behavior for existing clients and the local content broker.

Web opens search from the sidebar or Cmd/Ctrl+K, shows six recent meetings initially, and provides project/date/type filters, progressive results, image preview and detail navigation. Arrow keys/Enter select results, Cmd/Ctrl+1–9 activate numbered results, and Escape closes preview/search with focus restoration. Requests debounce for 300 ms, pause during IME composition, cancel obsolete queries and clear on Vault changes; background refresh preserves input and scroll. Text follows the existing English/Japanese browser language setting.

### Server hybrid search

Meeting and screenshot search is tokenized by the Server; it never reads Desktop's SQLite tokenizer or token data. Meeting search covers name, summary tags, description, and visible summary text. Screenshot search covers OCR and caption. Original transcripts remain synchronized but are not searchable. Queries are limited to 500 characters and 16 AND-combined tokens. Node uses the pinned Lindera IPADIC WASM package, while Cloudflare Workers use `Intl.Segmenter`; changing runtime for an existing database requires recreating it or fully resynchronizing every meeting.

`search.documents` (PostgreSQL/Lakebase) or `search_documents` (SQLite/D1) is the shared rebuildable projection for meetings and screenshots. PostgreSQL uses its generated `tsvector` with GIN, SQLite uses an external-content FTS5 table, and Lakebase uses `lakebase_text` with BM25. D1 sync is fail-closed until its multi-statement writes use D1's atomic `batch()` API. Lakebase Search must be enabled by an operator before deployment; startup stops when the required extension cannot be loaded. After the first full synchronization, update BM25 corpus statistics once with:

```sql
VACUUM search.documents;
```

Node also processes uploaded, canonically attached meeting images when `DAHLIA_CAPTIONING_MODEL` is set. The Databricks App service principal analyzes the existing bounded `thumb_1280` WebP variant; OCR stays in the original language (20,000 characters maximum), and captions use the owner's output language (500 characters maximum). Images and generated text are sent to the configured provider without logging request content. File-level durable jobs use five-minute leases and retry transient failures after restart. They preserve populated OCR/captions, accept empty OCR, and validate current ownership, checksum and revision before atomically committing canonical text, deltas, search projection and embedding jobs. Setting changes do not reanalyze completed images. Missing model configuration disables the corresponding worker; Workers do not run these Node jobs. The capabilities API advertises `imageAnalysis: { version: 1 }` only when Node has constructed the worker; Desktop retains device analysis when it is absent or its version is unsupported. Capability fetch failures retain the job for retry. Device fallback uses the Server account language settings when available, otherwise its existing device language settings. Files API storage currently requires Databricks Volumes.

### Full-text search weights

Administrators adjust **Server settings → Search settings** for the whole server. Each weight is adjusted with a horizontal slider showing its current value, in integer steps from 1 through 10: title **5**, summary tags **3**, description **2**, summary **1**, OCR **1**, and caption **2** by default. These values affect relevance, not whether a field is searchable. `GET /api/v1/admin/search-settings` reads the six values; `PUT` replaces all six with a strict JSON object such as `{"title":5,"tags":3,"description":2,"summary":1,"ocr":1,"caption":2}`. Both require a browser administrator session. Settings are stored in `server_settings`, separate from personal account settings; saves affect subsequent ranked searches without a restart or reindex.

`search_documents` stores separate tokenized `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, and `caption_text` columns. Meetings use the first four; screenshots use the last two. Tags come from the summary JSON's `tags`. Matching remains AND across all fields. SQLite uses FTS5 column-weighted BM25; PostgreSQL sums weighted field ranks; Lakebase sums field-specific BM25 scores with the default `k1=1.2` and `b=0.75`. Backend scores are not numerically interchangeable. Existing RRF fusion, candidate limits, authorization and tie ordering remain unchanged. The exhaustive text-search API retains its stable document-ID pagination rather than relevance ordering.

Lakebase disables BM25 index scans transaction-locally for weighted ranking so each field's top-K cutoff cannot discard a winning document before the scores are combined. This scores all filtered matches and can cost more for broad queries. Validate latency and `EXPLAIN (ANALYZE, BUFFERS)` on the intended corpus before deployment. See the [Lakebase BM25 reference](https://docs.databricks.com/aws/en/oltp/projects/lakebase-text) for scoring and corpus statistics.

The unreleased initial migration creates these fields and indexes directly. No legacy projection backfill or search rebuild is required for a new database. Existing development databases follow the empty-database baseline procedure above. `embedding_text` remains in use for semantic indexing and snippets; weight changes do not alter embeddings or require reindexing.

Run `pnpm exec vitest run tests/search-weighting.test.ts` for SQLite regression coverage. To exercise the same tests on PostgreSQL, set `TEST_SEARCH_DATABASE_URL` to a **dedicated disposable database owned by a non-superuser without BYPASSRLS**; the test applies the migration manifest and creates fixtures there.

`TEST_SEARCH_LAKEBASE_URL` runs the same tests against a dedicated Lakebase database with `lakebase_text` available. The test uses direct PostgreSQL connectivity, refreshes corpus statistics and sets the native candidate limit to one to detect early truncation; it must still return the correctly weighted top 100. Do not use an application database for either test URL.

### Account language settings

Authenticated users read `GET /api/v1/account/settings` and send `PATCH` with `outputLanguage` (`ja`, `en`, `zh`, `ko`, `fr`, `de`, `es`) and/or `analysisLanguages: { scope: "all" | "selected", identifiers: [...] }`. The scope and identifiers are one field; selected requires at least one identifier. Both routes return `{ settings }`; GET returns null before initialization. PATCH changes only supplied fields and returns the full canonical settings. Requests are limited to 8 KiB, and another identity's settings cannot be addressed.

Desktop initializes absent settings using its current local values and `initialize: true` with both fields; conditional INSERT preserves another device's settings. Before initialization, image analysis uses Japanese output and all languages. Same-field updates use the last server write. The existing SSE stream emits `account_settings` invalidations without settings content or a settings revision; clients refetch after reconnect and on settings display to recover missed notifications.

Desktop keeps these settings in memory only and disables edits when unavailable. Existing Server working copies can start, continue and stop recording offline with expired credentials or settings not yet fetched. Audio, finalized transcripts, images and queued sync operations remain on the existing local persistence path; only sync waits for reconnection or reauthentication. Local Account AI and device recording/transcription settings remain local. Server-account summaries are generated asynchronously on supported Node servers using the account output language; Local Account generation stays on Desktop.

Set `DAHLIA_EMBEDDING_MODEL` to enable asynchronous semantic indexing on Node; an empty or missing value keeps it off. `DAHLIA_SEARCH_EMBEDDING_DIMENSIONS` defaults to `1024` and accepts powers of two from 32 through 1024. The App service principal calls the Databricks embedding endpoint, and content or credentials are never stored in the queue. Lakebase uses `lakebase_vector` with `lakebase_ann`; other PostgreSQL deployments use pgvector's `vector` extension with HNSW. Install `vector` as a database operator before enabling embeddings when the application role cannot create extensions. SQLite performs exact cosine ranking in Node. Search automatically combines the top 100 FTS and vector candidates with RRF and falls back to FTS when embeddings are absent, rebuilding, or unavailable. Document text and the user's search query are sent to the configured embedding provider; Dahlia does not persist or log query text.

### Server summary generation

The optional `transcriptionModel` must support JSON Schema output, because remote transcription returns structured transcript segments rather than plain text.

`GET /api/v1/capabilities` includes `meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"] }` when the runtime has registered those generators. Sources identify the accepted primary inputs: transcript or recorded audio, and both may also use images. Node supports the configured Databricks backend; PostgreSQL/Hyperdrive Workers advertise the capability when a supported backend, summary Queue, and Images binding are configured. D1 Workers and unsupported backends omit it. An empty capabilities object also means summary generation is unsupported. There is no separate summary methods endpoint.

Account preferences separate intent from model API parameters:
`summary: { style: "concise" | "standard" | "detailed" | "eventSummary" | "eventTimeline" }` and
`processing: { location: "local" | "remote", remote: { workflow: "transcribeThenSummarize" | "combined", summaryModel?, transcriptionModel?, reasoningEffort? } }`.
Defaults are local processing, detailed style, and transcribe-then-summarize. Model and effort overrides are absent by default (Automatic). The Server resolves known preferred models against the shared `/api/v1/models` catalog and uses its default reasoning level. Explicit unavailable choices fail instead of being silently replaced. Styles map to existing job detail values only at execution.

Account settings are personal and shared across devices. `outputLanguage` applies to summaries and image captions even when the account processes on Mac. `analysisLanguages` is one atomic scope/list value. Mac inference provider/model/effort are device preferences, independent of both local and Server accounts. Web cannot execute local processing.

The settings page identifies the signed-in account before its preferences. Result style (with an explanation) and output language come first, followed by processing location; model and workflow overrides are in a collapsed advanced section. Changes save automatically. Initial loading or failure does not display editable placeholder defaults; failed refreshes preserve confirmed values read-only with a retry action. Mac processing explicitly describes the transcripts and images sent to that Mac's configured AI provider.

PATCH changes only supplied leaves, e.g. `{ "summary": { "style": "concise" } }`. Omitted fields are preserved; `null` clears summaryModel, transcriptionModel or reasoningEffort to Automatic. Switching location/workflow preserves inactive overrides. Null workflow/style, unknown keys and empty patches are rejected. Concurrent edits to distinct leaves are preserved; the last database write wins for the same leaf. No ETag or conflict revision is required.

The table keeps `user_id`, `output_language`, `analysis_languages`, `summary`, `processing`, and internal `revision`. PostgreSQL uses JSONB; SQLite/D1 use JSON text. Atomic partial updates increment revision only when supplied values differ. SSE polls this revision every two seconds; clients refetch on account-settings notifications and reconnect without reloading the model catalog or unrelated Web data.

Upgrade Server, Web, and Desktop together. Forward migrations move previous summary.mode/remote values into processing and semantic summary.style, preserving language and overrides. PostgreSQL temporarily relaxes FORCE RLS only inside the migration transaction and restores it before commit. Existing jobs/history are not rewritten; their accepted requests remain readable. Migration execution is explicit.


Explicit job retries retain the captured input references and settings, but recapture summary/transcript revisions and the input fingerprint under the Vault lock. Changes after retry acceptance still reject the result.

Model capability validation runs before taking the Vault transaction lock; authorization, input state, and duplicate requests are checked again before acceptance. Web retries refresh settings and recordings after a rejected input (HTTP 400), while uncertain transport outcomes keep the same request body and ID.

Owners start `POST /api/v1/meetings/{meetingId}/summary-jobs` with the following body (8 KiB maximum):

```typescript
type SummaryRequest = {
  id: string; // sjob_ TypeID backed by UUIDv7; stable across uncertain-response retries
  input:
    | { type: "transcript"; version: string }
    | { type: "recording"; recordings: { micFileId: string | null; systemFileId: string | null }[] };
  preferences: {
    outputLanguage: "ja" | "en" | "zh" | "ko" | "fr" | "de" | "es";
    summary: { style: "concise" | "standard" | "detailed" | "eventSummary" | "eventTimeline" };
    processing: {
      location: "remote";
      remote: {
        workflow: "transcribeThenSummarize" | "combined";
        summaryModel?: string;
        transcriptionModel?: string;
        reasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
      };
    };
  };
};
```

The meeting is identified only by the route. Transcript version selects an exact retained version; missing versions never fall back to latest. Recording pairs are ordered, nonempty and canonically attached to this meeting, with at least one track each. Unauthorized/mismatched files are rejected. Workflow explicitly selects separate recognition/summary or combined audio generation; inactive transcription overrides are ignored for combined generation. Both audio paths share the same transcript schema and validate model audio/structured-output capabilities. The preferences snapshot carries the account's output language independently of recognition language.

Acceptance freezes input, settings, language and conflict revisions and returns 202 with `{ job }` and `Location: /api/v1/meetings/{meetingId}/summary-jobs/{jobId}`. Reuse the same ID and body after an uncertain response; different content with that ID or another active job returns 409. GET that location returns that individual job; `/summary-jobs/latest` returns the most recent job. States are `pending`, `processing`, `succeeded`, `failed`, and `cancelled`. Processing stages are `transcribing`, `summarizing`, `generating` (combined), and `saving`. Failures include a bounded error code and the retained stage.

POST `summary/job/{id}/cancel` cancels an active job. POST `summary/job/{id}/retry` with `{ id: "<new sjob_TypeID>" }` retries a failed/cancelled job with its frozen input/settings and saved transcription checkpoint. A saved transcript survives summary failure; direct output is validated and committed atomically with both results. Cancellation and leases fence delayed output, and conflict revisions protect newer edits. Success follows durable canonical result storage. Existing inputless `{ id, detail?, outputLanguage? }` requests remain supported for existing transcript/audio clients, but cannot silently select cloud transcription.

Account `processing.location` is `local` or `remote`; `processing.remote` owns the remote workflow and overrides. All routes authenticate the current Vault owner; browser writes require the configured origin.

Jobs survive client closure and Server restart. A 5-minute lease fences completion; each generation attempt has a 4-minute deadline and at most three attempts. The Databricks App SP sends transcript requests through the existing Responses adapter with `store: false` and audio requests through Chat Completions without the unsupported `store` parameter, using strict structured output and the authenticated executor's `user_id` request tag. Interactive Gateway OBO behavior is unchanged. No new SDK or environment secret is required.

The transcript method reads only canonical transcript, images and meeting/Project context. Both methods sample up to 24 image bodies and exclude OCR, captions, and metadata for unsent images from model input. Both methods include the stored calendar snapshot in `<context><calendar_event>` with its iCal UID, recurrence ID, start/end timestamps and all-day flag, and include these values in input-change detection. Meetings without a snapshot omit that element. Calendar titles and descriptions remain device-local and are not sent by Server. Meeting/Project context and transcript text use escaped XML in `<context>` and `<transcript>`; each image is preceded by `<image>` with its ID and capture time. Each audio track is preceded by `<audio>` with its recording number, source, start/end times and manifest ranges. Stored OCR/captions, search, and input fingerprinting are unchanged. The shared response schema has no array-count maxima (`maxItems`) for sections, blocks, list items, tags, or action items, including post-generation validation. String lengths, numeric ranges, at least one section, required types/fields, screenshot references, and the 2 MiB response limit remain enforced. This avoids Gemini HTTP 400 without model-specific schema branches. Invalid output, changed input, deleted meetings and summary revision conflicts do not replace existing summaries. Successful canonical transactions update title/description, summary, search and delta state atomically with the job. Desktop waits for synchronization before starting and applies the result through normal delta sync without an echo. Export is a separate manual action for Server accounts. Web and Desktop refetch job state when reopened; polling does not carry document content.

#### Summary versions and latest reads

Every committed summary save (Server generation or Desktop sync) appends an immutable row to `summaries`: UUID `id`, meeting foreign key `meeting_id`, `version`, title, document, creation/save timestamps, and metadata. `(meeting_id, version)` is unique. The latest row is the maximum version; meetings store no summary body or latest pointer. Vault ownership and authorization are resolved through the parent meeting. Version allocation uses the existing Vault lock and is independent of `meetings.summary_revision`, which remains the sync/CAS counter. Retries do not create extra versions; failed generation or rejected transactions publish nothing. Versions are not subject to sync-ledger pruning. Server is unreleased: the forward schema migration replaces the old summary storage without a data backfill; registered migrations remain immutable.

All routes below inherit current Vault read access, including shared members, return `Cache-Control: no-store`, and work even when summary generation is unavailable:

- `GET /api/v1/meetings/{meetingId}`: meeting information and sync state only; no summary title, document or creation timestamp.
- `GET /api/v1/meetings/{meetingId}/summaries/latest`: the current canonical summary, using the text-content envelope (`formatVersion`, `version`, `entity`, `entityId`, `revision`, `present`, `count`, `byteCount`, `sha256`, `record`). `?manifest=1` omits the body. An absent/deleted summary has `present: false`; an inaccessible or missing meeting returns 404. It never falls back to a historical version.
- `GET .../summaries`: `{ items, nextCursor }`, newest version first, without document bodies. `limit` defaults to 20 (maximum 100); `cursor` is the exclusive version boundary returned by the previous page. Items include `id`, `meetingId`, `version`, `title`, `createdAt`, `savedAt`, and nullable `metadata`.
- `GET .../summaries/{version}`: the version metadata and document body, or 404. The path accepts digits only; `latest` and the generation `/summary-jobs` routes are separate paths.

Desktop fetches Server summary bodies through `latest`, checks their revision against synchronized metadata and verifies the existing content digest. A racing update triggers synchronization and one fresh read; it never mixes revisions or overwrites pending local edits. Web reads meeting information without a content-mode query and the current summary body only through `latest`, avoiding duplicate body downloads on live refresh. It allows read-only current and historical summary viewing. Deleting a summary removes **all** its versions atomically; deleting its meeting or Vault also removes the versions. After all versions are deleted, version allocation restarts at 1; the summary sync revision counter is not reset. The envelope `formatVersion` identifies the wire format; `version` identifies the content generation and `revision` the synchronized update. Desktop keeps its existing latest-only `summaries` and `summary_bodies` tables for local persistence and eviction; it does not mirror Server history.

`SummaryDocument.metadata` is optional. It contains `generatedBy` (`server` or `local_codex`), `inputTypes`, `detailLevel`, `outputLanguage`, `request: { model?, reasoning?: { effort?, summary? } }`, and optional `response`. `generatedBy` identifies the generating system; `inputTypes` identifies its inputs. The job method remains a job setting and is not duplicated in metadata. Response fields retain OpenAI Responses names: `id`, `model`, `created_at`, `reasoning`, and `usage` (`input_tokens`, `output_tokens`, `total_tokens`, `input_tokens_details.cached_tokens`, `output_tokens_details.reasoning_tokens`). Only available fields are retained; missing metrics are never estimated or filled with zero. The request model is the actual model sent to the provider; the returned model is stored separately. No raw provider output, input snapshot, credential, custom timing, or prompt-version record is added. These fields describe content provenance, not a trusted authentication or audit identity.

Local Codex writes the same document shape with known request settings and inputs; it does not fabricate response metadata. Desktop currently stores the current document only and offers no version selector. Manual summary editing clears generation metadata, while sync, unchanged saves and rehydration preserve it. Deploy the new migrations first, then update Server and its Web assets together, then Desktop. Summary generation uses the explicit input and staged job API documented above. The unreleased `/summary/versions`, `/summary/versions/{revision}` and `text/summary` paths are removed without aliases or fallbacks. The published Desktop v0.21.0 does not use these sync/summary APIs. Development clients expecting summaries in meeting detail or the removed paths must update; Server MCP retains its existing summary-inclusive `get_meeting` result through the internal canonical read. Snapshot/delta now always use the body-free contract documented above.

Custom Node entry points can import `SummaryService`, `SummaryWorker`, `createTranscriptSummaryMethod`, and `createAudioSummaryMethod` from `@dahlia-ai/server/node`, use `applicationStore.summaryJobs`, pass `summaryService` to `createApp`, and start/stop the worker with the process lifecycle. See [the summary ADR](../../docs/adr/server/summary-generation.md) for input limits and the audio method boundary. Audio upload/retention is unchanged by this feature.

### Read-only MCP

`POST /mcp` is a stateless, modern-only MCP 2026-07-28 endpoint. Both `mcp` and `mcp:read` expose read-only search, Project, meeting, transcript, and screenshot tools. Each tool uses current Vault authorization. MCP requests are rejected above 12 MiB before JSON parsing, including streamed requests without `Content-Length`. Screenshot results contain authenticated resource links.

In `accounts` mode, `/mcp` requires a DPoP-bound access token for the exact MCP resource and either `mcp` or `mcp:read`; only tools covered by the granted scope are registered. In `header` mode, authentication is delegated to the trusted proxy and Dahlia derives ownership from its verified forwarded identity headers. Databricks Apps exposes custom MCP servers at `/mcp`; its proxy has already authenticated the request, and `X-Forwarded-Access-Token` is not used for object storage. A present `Origin` must match the configured application origin; non-browser clients may omit it.

`DAHLIA_STORAGE_BACKEND` selects `local`, `s3`, `databricks`, or `r2`. Node defaults to `local` under `DAHLIA_STORAGE_LOCAL_PATH=.data/storage`. Databricks uses `DAHLIA_STORAGE_DATABRICKS_VOLUME_PATH=/Volumes/<catalog>/<schema>/<volume>`. S3 uses `DAHLIA_STORAGE_S3_BUCKET`, optional `DAHLIA_STORAGE_S3_ENDPOINT`, and the standard `AWS_*` credential variables. Workers must explicitly select `r2` with the `DAHLIA_STORAGE` binding or `s3`; they reject the local default.

`header` reads the authenticated email from `X-Forwarded-Email` by default. Override the email header name with `DAHLIA_AUTH_HEADER`, for example `Cf-Access-Authenticated-User-Email`. `X-Forwarded-User` supplies the stable user ID and `X-Forwarded-Preferred-Username` supplies the display name; when absent, the email remains the user ID. The upstream proxy must remove client-supplied identity headers, write the verified values itself, and prevent direct access to the Server.

`DAHLIA_APP_URL` sets the canonical public application origin used for OAuth metadata and browser mutation checks. When it is absent, Dahlia uses `DATABRICKS_APP_URL`, then falls back to `http://localhost:5173` for local development.

## Provider and model configuration

The AI backend uses the OpenAI Responses-compatible contract and is independent of the database. Select `databricks`, `cloudflare`, or `openai` with `DAHLIA_AI_BACKEND`; it defaults to `openai`. While the selected non-Databricks backend has no `OPENAI_API_KEY`, `/api/v1/models` returns an empty standard model list and a Codex catalog with no picker-visible models, while Responses returns `503 provider_not_configured`.

`GET /api/v1/models` returns the standard OpenAI `object` and `data` fields together with the `models` catalog required by Dahlia's bundled Codex. Omitting `client_version` selects the latest supported bundled version, currently `0.153.4`; callers may also request `client_version=0.153.4` explicitly. Other explicit versions return `400 unsupported_codex_client_version`. Each AI backend returns both representations directly; model discovery no longer reads Model Alias rows. OpenAI returns a fixed mock catalog containing `gpt-5.6-luna`. Cloudflare retains that ID and adds `gpt-4.1` (text/image, reasoning `none`) and `gemini-3-flash` (audio, reasoning `minimal`, `low`, `medium`, `high`). Short IDs map to their `openai/` or `google/` upstream names. Cloudflare catalog entries include `summary_methods`: GPT-4.1 supports `transcript`, Gemini supports `audio`, and Luna supports neither background method. Web and Desktop use this metadata for both direct and staged summary model choices; absent metadata retains the existing Databricks capability rules. The Server owns the reserved `codex-auto-review` override independently of every backend. Set `CODEX_AUTO_REVIEW_MODEL` to expose that alias as `Codex Auto Review` and route automatic approval reviews to the configured upstream model; an empty or missing value uses the backend model normally, including a discovered `codex-auto-review` service. The environment override wins over any backend model with that reserved ID and is forwarded verbatim, without Databricks schema prefixing. Codex picker and runtime metadata comes from Dahlia-owned model catalogs; unregistered models remain in `data` but are not added as usable Codex models. TypeScript does not infer capabilities from model names. Databricks GPT entries retain upstream transport, tool, and service-tier metadata; actual upstream protocol support must be verified separately. Updating the bundled Codex requires updating this Server catalog and its contract test in the same change.

`src/ai-gateway/databricks-models.json` is maintained directly. GPT entries copy [Codex models.json at 713caa89](https://github.com/openai/codex/blob/713caa89f389acd9cbcd77016edbb607273826af/codex-rs/models-manager/models.json) (main checked 2026-09-10), selecting only GPT-6, GPT-5.6, and GPT-5.5. For usable GPT entries, the only changes to those upstream objects are hyphenated slugs and `available_in_plans: []`. Display names, priority, instructions, transport flags, and other values remain upstream values. Future GPT setting changes require user confirmation unless already explicitly authorized. The bundled client remains 0.153.4; refreshing catalog metadata does not upgrade it.

OSS entries use official documentation for known capabilities. Missing runtime values are copied into JSON from GPT-5.6 Luna for lightweight models and GPT-5.6 Sol for large models; this is a maintenance-time reference, not runtime inheritance. Their instructions replace the GPT identity sentence with a generic coding-agent identity. Non-GPT entries set `use_responses_lite: false`: the bundled Codex Lite path moves tool definitions into `input.additional_tools` and requires an internal header, while Dahlia relays the standard Responses contract. Gemini is also Dahlia-maintained and has `visibility: "list"`, so discovered Gemini models appear in the picker with their audio/structured-summary metadata. `codex-auto-review` retains the existing reserved review configuration. All Databricks entries have empty `available_in_plans`.

| Model | Reference for unspecified values | Official capability source |
| --- | --- | --- |
| GLM 5.3 | Sol | [Z.ai](https://docs.z.ai/guides/llm/glm-5.3): text, 1M context, low/high/max reasoning with max default |
| GLM 5.3 Flash | Luna | [Official model card](https://huggingface.co/zai-org/GLM-5.3-Flash): text/image, 1M-context evaluation, low/high/max with max default |
| Kimi K3 | Sol | [Official model card](https://huggingface.co/moonshotai/Kimi-K3): native vision, 1,048,576 context, low/high/max with max default |
| DeepSeek V4 Pro 0813 | Sol | [Model specification](https://api-docs.deepseek.com/quick_start/pricing/) and [thinking guide](https://api-docs.deepseek.com/guides/thinking_mode/): 1M context, low/high/max with high default; none disables thinking |
| Gemini 3.8/3.7 Flash | Luna | [3.8](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash), [3.7](https://ai.google.dev/gemini-api/docs/models/gemini-3.7-flash): text/image/audio, 1,048,576 input tokens, low/medium/high reasoning; hidden from Codex because its tool contract is incompatible |

Where a source states only 1M, the catalog uses 1,000,000 tokens. Video/PDF are not added to `input_modalities`, which uses the bundled Codex text/image/audio vocabulary. Provider capabilities and GPT-derived runtime defaults do not prove Databricks endpoint support.

`models.ts` joins discovery results to the chosen JSON catalog by exact slug and returns matching objects unchanged. Publication in both `data` and API-supported `models` is the structured-output capability contract: operators must publish only JSON-schema-capable models. Server and Desktop do not require the legacy `supports_json_schema` flag. Audio modalities and `summary_methods` still constrain the permitted summary workflows. It does not normalize IDs, rewrite prompts or priorities, infer capabilities, or synthesize usable model entries. Mechanically generated suppression entries with `visibility: "hide"` and `supported_in_api: false` are returned even without discovery; other entries require an exact discovery match. Unknown IDs remain in standard `data`; empty Databricks discovery returns only the generated hidden entries. Standard `data[].display_name` prefers a nonblank provider name, then the JSON display name, then the original ID. Codex `models[]` retains JSON display names. These generated entries suppress the corresponding bundled Codex choices.

The existing OpenAI mock and Cloudflare IDs/settings are maintained separately in `openai-models.json` and `cloudflare-models.json`, so their dotted IDs and GPT-4.1 entry do not require conversion rules or exceptions in the Databricks catalog.

The administrator organization directory links to `/admin/organizations/{organizationId}`. Server administrators can read the organization name, slug, members, and teams even without membership, through `GET /api/v1/admin/organizations/{organizationId}` (independent `membersOffset` and `teamsOffset`, 100 rows per page). Members retain a link to the existing organization management page; organization mutations still require their organization role. This directory access grants no Vault or meeting access.

The first authenticated user becomes the initial administrator. Administrator roles are stored in Better Auth's `auth.user.role`; additional registered users can be promoted or demoted under `/admin/members`.

OpenAI or another OpenAI-compatible provider:

```dotenv
DAHLIA_AI_BACKEND=openai
OPENAI_API_KEY=...
# OPENAI_BASE_URL=https://api.openai.com/v1
```

Non-local provider URLs must use HTTPS. Model Alias management UI and `/api/v1/admin/models` endpoints have been removed. The unreleased baseline also removes the Model Alias table, CRUD methods, and exported types. `GatewayService` takes `(config, transport?)` without a database store.

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

`GET /api/v1/models` uses the App service principal to list all pages of Model Services under the required `DATABRICKS_MODEL_SCHEMA` (`catalog.schema`, for example `dahlia.ai`; specify catalog and schema names in lowercase). Names containing `embedding` are excluded; all remaining services are exposed in the standard `data` list. The Codex `models` catalog includes discovered entries defined in the provider catalog and the registered reserved `codex-auto-review` alias. Gemini 3.8/3.7 Flash remain API-supported for audio summaries but use `visibility: "hide"` because Codex cannot use their tool contract. Desktop and Web model selectors also hide `codex-auto-review`; the API still returns it for automatic reviews. Hidden built-in entries for Codex 0.153.4 are mechanically generated by models.ts and always returned in the Databricks Codex catalog, with supported_in_api: false, to suppress dotted GPT IDs and Daybreak entries. They are not added to discovery data. Discovery does not inspect `supported_api_types` or issue individual GETs. Operators must include `embedding` in embedding service names and register Responses-compatible models under other names. The configured `CODEX_AUTO_REVIEW_MODEL` override is trusted without capability discovery. Model IDs are returned as short names such as `gpt-5-6-luna`; the Databricks backend prefixes that configured schema when forwarding Responses. Fully qualified model IDs from clients are rejected. The Server-controlled `CODEX_AUTO_REVIEW_MODEL` override is exempt and is sent unchanged. Databricks requires `DATABRICKS_CLIENT_ID` and `DATABRICKS_CLIENT_SECRET`; Apps injects both at runtime. Desktop authorization requests `all-apis`; the App keeps the `ai-gateway` and `files` OBO scopes.

The Worker-safe `AIGatewayBackend` interface provides `listModels(request)` and `responses(body, context)`. `RequestBody` is the shared Responses payload; `input` may be omitted (for example with a stored prompt), and nullable `max_output_tokens` / `stream` values are forwarded unchanged; `RequestContext` carries verified `identity.userId`, incoming headers, cancellation, and an optional Server-resolved `upstreamModel`. Implementations read only necessary incoming headers and construct upstream headers explicitly. Databricks sends the verified user ID as `user_id` in `Databricks-Ai-Gateway-Request-Tags` for upstream usage attribution; client-supplied tags cannot override it. User IDs and content are not written to Dahlia diagnostic logs.

Cloudflare AI Gateway:

```dotenv
DAHLIA_AI_BACKEND=cloudflare
OPENAI_API_KEY=<cloudflare-api-token>
OPENAI_BASE_URL=https://api.cloudflare.com/client/v4/accounts/<account-id>/ai/v1
```

This uses Cloudflare's account REST API. The token needs Account > Workers AI > Read; select a gateway with `CLOUDFLARE_AI_GATEWAY_ID` (default `default`). Gateway logging, payload logging, caching and additional attempts are disabled. See [background job configuration](../../deploy/cloudflare/README.md#postgresql-background-jobs) for the Node/Workers provider matrix, bindings and byte limits.

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

`pnpm dev` / `pnpm dev:api` enables sample data for local SQLite when `DAHLIA_APP_URL` uses localhost or a loopback address. After normal sign-in, a user with no accessible Vaults receives a sample Vault, a Project, and three meetings with summaries (including an unclassified meeting). Existing data is left untouched; repeated requests and restarts do not duplicate the sample while a Vault exists. All generated content and transaction IDs use UUIDv7, and the normal transaction service handles SQLite serialization and search indexing. PostgreSQL, Lakebase, Workers, and `pnpm start` do not seed data. To check an empty state, delete the sample Vault during the same development process; restarting with no Vaults seeds it again. Google sign-in configuration is still required in accounts mode.

Set `DAHLIA_DATABASE_TYPE=postgres` and `DAHLIA_DATABASE_URL` to move Better Auth and Gateway administration to PostgreSQL, or set `DAHLIA_AUTH_TYPE=header` for an identity-aware proxy.

For `accounts`, configure the Google OAuth callback as `http://localhost:5173/api/auth/callback/google` locally or `https://<host>/api/auth/callback/google` in production.

The first registered user becomes the Server administrator. In accounts mode, that user's authenticated request also initializes owner membership in `Default Organization` (ID / slug: `external`), including on existing databases with an administrator. No initial team is created. Existing organizations still named `external` are renamed on authenticated access; custom names and existing teams are preserved. Teams can be removed even when they are the last team. Later Google users are not automatically enrolled; invite them through the organization UI. This default organization initialization applies to all Server runtimes, independently of development sample data. Organization creation, its initial owner membership, and a durable initialization record are atomic. Migrations mark existing default organizations as initialized. Explicitly deleting the organization does not recreate it on later sessions or after a restart. Accounts-mode membership removals and role changes are preserved; deleting the initial account does not re-enroll another user. Existing organization ownership is preserved, and Vault access still requires ownership or explicit sharing.

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

### Private Web workspace

Home shows the accessible Vaults and the ten most recent meetings from a selected Vault.
Live updates preserve that selection, including the initial default, while the Vault remains accessible.
The sidebar exposes Home, All Vaults, the current Vault selector, search beside the logo, and the Project tree;
The account menu contains Account settings, organization switching ("No organization selected" without an active organization), and sign-out.
Server administrators have a separate bottom sidebar section for Organization management, User management, and General settings.
`/admin/organizations` includes organizations the administrator has not joined; `/admin/users` lists registered users and the existing administrator controls.
The read-only directories use administrator-only `GET /api/v1/admin/organizations` and `GET /api/v1/admin/users`, with pages of 100 and an `offset` query parameter.
They expose directory metadata only and do not grant access to other users' Vault content. `/admin/settings` is currently an empty settings page.
Members can reach their organization settings from the sidebar; administrators use "Manage your organizations" on the organization directory.
Account extension links, such as billing, live on Account settings. Administrator extension links live in the Server section.
At widths up to 820px the same
navigation becomes a native modal drawer, with Escape, backdrop dismissal and focus containment.
Selecting a destination closes the drawer even when it is already the current page; canceling search keeps it open.
Meetings retain their readable Summary, Screenshots and Transcript tabs, breadcrumbs and owner-only actions.

Creation, editing, deletion and session revocation use native HTML dialogs styled consistently
with the workspace. Editors retain multiline drafts after errors, protect dirty drafts from
accidental dismissal, and block duplicate submissions and dismissal during a save. Destructive
confirmations explain their scope and initially focus Cancel. Closing restores focus to the
opener. Summary edits preserve block structure, IDs, tables, references and attachments; a changed
manual version clears generation metadata, following the existing summary contract.
Single-value fields use `src/client/Select.tsx`; its trigger, menu, and row styles are shared with the Vault selector. Keep new dropdowns on this component so keyboard navigation, disabled states, and modal focus behavior stay consistent.
`/tests/browser/select.html` checks picker interactions and `/tests/browser/account-settings.html` checks saving through those controls.

Settings report automatic-save progress and success. Narrow layouts use larger touch targets;
search exposes active filter counts, a clear-filters action and keyboard selection to assistive technology.

For visual review, open `/tests/browser/live-data.html?preview&lang=ja` on the Vite origin.
Add `&page=home`, `&page=vault`, or `&page=settings` for other views; omit `lang=ja` for English.
These are local fixtures, not live account data. Reopen the fixture URL after a development reload.
`/tests/browser/dialogs.html` runs the draft, validation, focus, duplicate-submit, pending-operation
and destructive-confirmation regression checks; success sets `document.body.dataset.testResult` to `passed`.

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

### Audio summary generation

Node and PostgreSQL/Hyperdrive Workers with the Databricks or Cloudflare backend support `meetingSummaryGeneration.sources: ["transcript", "audio"]`. In Private Web, **Processing location** selects local Mac or remote Server processing; remote processing can optionally transcribe before generating the summary. Audio model choices use the existing `/api/v1/models` list, restricted to Gemini models whose catalog metadata includes audio input. The worker validates the model and reasoning effort against that same catalog before reading recording bytes.

`GET/PATCH /api/v1/account/settings` exposes `summary.style`, `processing.location`, and remote workflow/model/effort preferences. See Server summary generation above for Automatic defaults, leaf PATCH semantics and immutable job snapshots.

Audio generation reads all committed mic/system recordings across all sessions, alongside meeting/project context and the existing sampled screenshots. It sends the original `audio/mp4` through Databricks Chat Completions `audio_url` inline data, streaming Base64 and verifying size/checksum without buffering whole recordings. It does not send transcript text, transcode audio, publish recording URLs, or persist intermediate transcripts. Start times and manifest ranges provide alignment across parallel tracks and screenshots.

The combined duration of all audio files, counting mic and system separately, must not exceed **9.5 hours**. No shorter application duration limit or automatic splitting is imposed. Missing audio (`summary_audio_empty`), duration overflow (`summary_audio_too_long`), and upstream HTTP 413 (`summary_audio_request_too_large`) are explicit failures; audio is never truncated or replaced with transcript input. Provider request limits and the existing four-minute generation timeout still apply. Input changes, authorization loss, invalid responses, and summary conflicts preserve the current summary and history. Transcript-only changes do not invalidate audio jobs.

Update Desktop before enabling audio generation on Server, and apply the new PostgreSQL/SQLite/D1 `audio_summary` migration before updating Server and Web. Desktop displays and edits the selected source settings, filters audio models to audio-capable Gemini, and uses the common detail for individual and batch generation. Workers advertise generation methods when a supported provider, summary Queue and Images binding are configured; D1 does not support these jobs. Custom Node entry points should register both available factories with the existing service and worker. No Google API key or additional dependency is required.

### Recording audio

New Desktop batch recordings use a dedicated API, separate from Files:

- `PUT /api/v1/meetings/{meetingId}/recording-uploads/{sessionId}/audio/{source}`: raw `audio/mp4` with Content-Length, at most 1 GiB. New bytes return 201; identical retry returns 200; different bytes return 409. The response includes `id`, `source`, `contentType`, `size`, `checksum` (`SHA-256:<hex>`), and `contentUrl`.
- `recording:upsert` in `/api/v1/transactions`: `entityId` is the `rec_` TypeID for the internal recording session UUID, data contains `source`, `checksum`, and `manifest` (`sampleRate: 16000`, `frameCount`, and ranges with `startFrame`, `frameCount`, `sessionOffsetSeconds`, `localeIdentifier`). PUT staging is private to the owner until this commit.
- `GET /api/v1/meetings/{meetingId}/recordings`: committed recordings in number order, up to 200 items, `nextCursor`; each item has integer `id`, `startedAt`, `endedAt`, and `audio.mic` / `audio.system`. No internal session UUID.
- `GET/HEAD /api/v1/meetings/{meetingId}/recordings/{number}/audio/{source}`: current Vault read access, byte ranges, private caching. No physical storage URL is exposed.

Numbers are allocated atomically per meeting and shared across sources of one session. Keys are `meetings/{meetingId}/recordings/audio_mic_01.m4a` and `audio_system_01.m4a` beneath the configured storage root, including Databricks Volumes. Committed audio has no retention expiry. Meeting/Vault deletion queues physical deletion; staging expires after 24 hours. Node scans all Vaults every minute, and the Worker scheduled handler uses the templates’ once-per-minute Cron Trigger, so expiration does not require subsequent Vault traffic. The scan uses paginated operational metadata and owner-scoped transactions, then drains the existing durable deletion queue. Existing Files limits remain unchanged.

Capabilities advertise `sync: { version: 4 }`, `meetingEvents: { version: 1 }`, and `recordingArchive: { version: 1 }`. Deploy Server and Web together, then Desktop. Old development Desktop clients pause sync on the new Server; new Desktop clients require an update of old Servers. These sync APIs are unreleased; no backward compatibility routes or fallbacks are retained. Update Server/Web and Desktop as one release. Summary and Transcript versioning add forward migrations for the fresh Server schema and a data-preserving Desktop migration.

The 1 GiB application limit does not override upstream proxy or platform request limits/timeouts. Validate the selected Node/Databricks/Worker deployment with representative long recordings before enabling source deletion; some Worker plans/proxies may reject a request below this limit. Audio recognition remains on Desktop. See [the ADR](../../docs/adr/shared/recording-audio-archive.md) for quality/release gates.

Cloudflare's [current request body limits](https://developers.cloudflare.com/workers/platform/limits/) depend on the account plan (Free/Pro: 100 MB; Business: 200 MB), so the application's 1 GiB cap is not a promise that these plans can upload 1 GiB in one POST. Staging becomes unreadable/uncommittable at 24 hours; upload and sync-change requests sweep expired metadata into the persistent deletion queue. Physical removal can wait until the next request if the deployment is idle.

Search UI regression: run `pnpm dev:client`, open `/tests/browser/search.html`, and verify `document.body.dataset.testResult === "passed"`. It uses isolated fixtures for IME, debounce, cancellation, navigation, preview, focus, refresh and Vault switching.
Summary worker diagnostics use structured `summary_job_started`, `summary_job_succeeded`, `summary_job_lease_lost`, and `summary_job_failed` events. Failure records include the generation/publish phase, bounded error code, attempt, retryability, duration, and an upstream request ID when supplied. They never include meeting content, prompts, provider response bodies, model/user/meeting identifiers, or credentials. A `summary_input_changed` failure means canonical input changed after enqueue; wait for transcript/image processing to finish, then retry. The existing summary is preserved.

The sidebar groups Home, Vaults, and Search into an icon row with accessible names and tooltips. The current Vault button opens a popover with the selected Vault marked.
Unassigned meetings appear in their own sidebar section below the project tree.
Selected sidebar navigation expands to show its label. The shared `Tooltip` component provides hover/focus help, optional shortcuts, and Escape dismissal.
Vault selection and management live in the sidebar; the account menu contains account and organization actions.
Vault owners can delete an empty Vault from its Settings tab after confirmation. Vault detail includes `hasResources`; the client disables deletion while resources remain. The revision-checked `vault:reset` transaction with `preservePermissions: false` also rejects Projects, Meetings, or Files (including staged Files) with `409 vault_not_empty`, then returns to Vaults after a committed receipt. The owner-only restore operation with `preservePermissions: true` retains its reset semantics.
Account settings are accessed through the account menu without a separate footer settings icon.

### Collection appearance and permissions

Vault and Project edits include an icon and color beside the name. Appearance is
stored as `{ icon, color }` on the canonical Vault/Project and travels through
transactions, snapshots and changes to Desktop. Omitted appearance in transaction writes preserves an
existing value; canonical reads replace the appearance, including clearing it when null; root collections without one use the default icon. Child Projects always inherit their parent's appearance and show a read-only icon in the editor. Child create/update payloads reject explicit appearance; demotion to a child clears any stored appearance. Desktop's older
local Project preferences remain a fallback and become canonical when saved in
the Project editor. New nullable columns are added by forward migrations.

The Vault **Permissions** tab opens **Manage sharing**, a searchable modal for organizations, teams, and users, with a distinct icon for each type and an accessible search field without a visible label. Changes apply immediately and grant read-only access. The owner-only `GET /api/v1/vaults/{vaultId}/permission-targets?q=...` searches the owner’s organizations, their teams, and fellow members by name or email (up to 50 results per type per page; pass `nextCursor` as `cursor` with the same query, or use **Show more** in the modal). Existing grants remain searchable for revocation after membership changes. Owners grant or revoke direct access through `PUT` / `DELETE /api/v1/vaults/{vaultId}/permissions/users/{userId}`; new user grants require a shared organization and cannot change ownership. Members see their read-only status. The **Settings** tab contains
Vault details and deletion. The permissions tab is always available.

### Transfer all Vault content

Owners can move all Server-saved content to another Vault they own with
`POST /api/v1/vaults/{vault_id}/transfer`, `Idempotency-Key: <txn_TypeID>`, and
`{"destinationVaultId":"<vlt_TypeID>","sourceRevision":3,"destinationRevision":5,"audienceHash":"<preview hash>"}`.
The atomic response is `200 {"id":"<txn_TypeID>","status":"committed","sourceVaultId":"<vlt_TypeID>","destinationVaultId":"<vlt_TypeID>"}`.
IDs and object-storage keys remain unchanged; the empty source Vault remains and deletion is separate.
Retries with the same owner/key/body return the saved result; key reuse with a different body returns `409 idempotency_key_reused`.
Identical Vaults return 400; missing or non-owned Vaults return 404. Stale revisions, staged data, running work,
and normalized root-Project name collisions return distinct 409 errors.

`GET /api/v1/vaults/{vault_id}/transfer-audience?destinationVaultId=<vlt_TypeID>` returns the current readers gaining or losing access and their `audienceHash`. Submit that hash with the transfer; a changed reader set returns `409 transfer_audience_changed` and requires a new confirmation. PostgreSQL locks sharing and membership writes until the checked transfer commits.
Transferred content inherits destination sharing. Desktop retains local data and pauses when destination access is unavailable,
then checks again after access is restored. Unsynced local changes also pause relocation; they are never discarded automatically.
`GET /api/v1/vaults/{vault_id}/relocations` resolves transferred IDs to their current accessible Vaults, including after delta expiry.
Clients declare support with `X-Dahlia-Vault-Transfers: 1`; affected Vaults reject older sync clients with 426.
There is no transfer-history acknowledgement or client transfer cursor.

Organization management: the account menu links to your organizations. Member invitations and team creation use dialogs; team membership expands within each team and saves immediately. Invitation links must be shared manually (no automatic email). Server administrators can inspect the separate server-wide organization directory.

Project details use Meetings and Settings tabs. Project editing and deletion are available to Vault owners from Settings.


### Local background-job runtime validation

Use a **disposable, migrated PostgreSQL database**, owned by a non-superuser without BYPASSRLS. From `apps/server`:

```bash
TEST_DATABASE_URL=postgresql://test@127.0.0.1:55491/dahlia_jobs pnpm exec vitest run tests/jobs-postgres.test.ts
TEST_DATABASE_URL=postgresql://test@127.0.0.1:55491/dahlia_jobs pnpm test:worker
```

The workerd check uses Wrangler's installed Miniflare and local R2/Images/Queue bindings, validates independent event connections and checksum-verified audio streaming, and reports its test bundle size and startup time. It creates only local temporary state and uses synthetic inputs; it does not contact an AI provider or provision Cloudflare resources. `pnpm check` separately verifies the deployment bundle. Real Hyperdrive, provider credentials and production Images remain deployment checks.

### Live transcripts

The read-only MCP tool `get_meeting_transcript` returns confirmed speech for the whole meeting through ordinary transcript sync. Pass the returned `next_after` as `after` to retrieve additions; `wait: true` waits up to 25 seconds only when no speech is available. Empty results retain a checkpoint. Existing `cursor` pagination remains available, but cannot be combined with `after`. An edit, deletion, regeneration or late insertion into already-read speech returns `transcript_changed_refetch_without_after`: omit `after` and rebuild the transcript.

Each wait iteration releases its transaction, revalidates authentication and Vault permissions, and stops on disconnection. `query_meetings` reports `isRecording` from synchronized start/end events; this does not prove live connectivity. No preview storage, live HTTP routes or separate SSE subscription is needed. See [MCP transcript access](../../docs/live-mcp.md) for Local MCP registration and the shared read contract.

## Server Vault encryption

New Vaults accept `encryption: "none" | "server"` in the create Transaction. Omission defaults to `none`; omission on update preserves the mode. Private Web offers the choice when the authenticated capabilities response advertises `vaultEncryption`. Existing Vault modes cannot change, and transfers involving an encrypted Vault return `409`. Desktop needs no key: authorized Server reads return the usual plaintext records.

This protects canonical content from direct database reads, with an explicit exception: all search data (text, vectors and indexes) in `search.documents` / `search_documents` remains unencrypted and can expose searchable meeting text, summaries, OCR and captions. File bodies, recording objects, Desktop working copies, authentication data, IDs, relationships, dates, statuses and other operational fields are outside this protection. It is not end-to-end encryption; the Server holds the keys and decrypts for authorized clients and jobs. See the [design and protection boundary](../../docs/adr/server/vault-encryption.md).

Configure individually named runtime secrets, each containing base64 of exactly 32 random bytes, and an explicit active ID:

```dotenv
DAHLIA_ENCRYPTION_MASTER_KEY_1=<base64-32-byte-secret>
DAHLIA_ENCRYPTION_MASTER_KEY_3=<base64-32-byte-secret>
DAHLIA_ENCRYPTION_ACTIVE_KEY_ID=3
```

IDs may have gaps. Never reuse an ID for different key bytes. Do not place keys in the application database, database backups, logs or source control. Node and Workers use the same names; inject Worker keys as secrets. Missing or invalid configured keys fail initialization; missing keys for an existing encrypted Vault or corrupt ciphertext fail reads with `vault_encryption_unavailable`, without plaintext fallback. D1 meeting sync remains disabled.

The unreleased Server initial migrations include this schema. Apply them to a fresh database with `pnpm db:migrate` (packaged deployment: `pnpm db:migrate:prod`), configure secrets and restart before creating encrypted Vaults. Existing development databases need an explicit rebuild or migration before using this revised initial schema; startup does not rewrite them. Database backups are not modified.

To rotate, add a fresh numbered key, retain old keys, set its active ID and restart all writers. From `apps/server`, validate the database's wrapped keys before applying:

```bash
pnpm db:rotate-encryption-keys
pnpm db:rotate-encryption-keys --apply
```

The packaged command is `pnpm db:rotate-encryption-keys:prod` (append `--apply` to mutate). Dry-run is the default; output contains counts only. Rotation rewraps each Vault key, leaves content ciphertext unchanged, commits in batches and can resume after interruption. It includes retained keys for deleted Vault receipts. Keep old master keys as long as a retained backup requires them; a live rotation does not rewrite backups. Restore the database together with its matching master-key set and verify an encrypted read before switching traffic. Workers using PostgreSQL can rotate through this Node command against the same database with its normal scoped database credentials.

Search text and vectors share one table: PostgreSQL/Lakebase `search.documents`, SQLite/D1 `search_documents`. `embedding` is NULL until generated; `embedding_model` identifies its model. Vector length is validated against configuration and no dimensions column is stored in the document. `jobs.search_index` remains a separate durable queue. Search performs no encryption or decryption; PostgreSQL/Lakebase use native DB ranking and SQLite retains exact cosine ranking.

`embedding_text` is not stored. Jobs use the existing tokenized `search_text` projection, including meeting title, tags, description and summary or image OCR and caption. The existing `embedding_content_hash` is the hash of this exact input. A changed input clears the vector and its model atomically with the projection update. Saving requires the latest hash, the claimed job generation/model and current ownership to match; a deleted document cannot be recreated by a delayed result. Queries require the configured model and vector length, so model changes fall back to FTS until regeneration. No Meeting/image version or second vector hash is added.

### Updating an existing development database

The Server is unreleased; the initial Drizzle migrations were rewritten. An already-applied migration ledger will **not** apply this change on `pnpm db:migrate`. Do not clear the ledger or run the fresh baseline over populated tables. No existing database is deleted, reset or automatically converted by this change.

Before running this code against an existing development DB, stop its writers/index workers and take a consistent backup (including encryption keys separately). On a restored copy, prepare an explicit schema/data upgrade for that DB's actual baseline: move PostgreSQL `app.search_documents` to `search.documents`; add nullable `embedding` and `embedding_model` (SQLite keeps its table name); retire the old `search_embeddings` table only after validating the replacement. Old vectors and hashes used different input or ciphertext and must be regenerated, not copied as valid results. Rebuild projections and their hashes from canonical content through the current sync service, clear obsolete search jobs, and regenerate vectors using the configured model. Preserve canonical records, keys, permissions and all unrelated data. Restore/verify the document foreign key, indexes, Vault RLS and FORCE RLS in the search schema, including any runtime-role schema grants. Test search, deletion and encrypted reads on the copy before applying an explicitly reviewed upgrade to the original. D1 sync remains disabled. This upgrade is separate from the rewritten fresh-install migration; production migration and deployment are outside this change.

PostgreSQL encryption/RLS checks use `TEST_ENCRYPTION_DATABASE_URL` pointing to a dedicated disposable non-bypass-RLS database. These checks do not substitute for deployed Lakebase or Worker testing.

PostgreSQL job tables live in `jobs.summary`, `jobs.image_analysis`, `jobs.search_index`, and `jobs.storage_delete`; SQLite/D1 keep `jobs_*`. The application role owns these schemas and tables; no new PUBLIC grants are added. For existing development databases, follow the [data-preserving jobs schema move](docs/jobs-schema-move.md) before starting the updated server. Editing the unreleased baseline does not migrate an existing database.
