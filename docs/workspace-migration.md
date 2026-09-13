# Workspace migration

Workspace is the same resource previously called Vault. Local and Server accounts use the same vocabulary; ownership, sharing and recording behavior are unchanged. Organizations own Server Workspaces, Projects belong to Workspaces, and organization membership alone does not grant content access.

## Current contracts

- Swift and TypeScript use `Workspace` and `workspaceId`. MCP preserves its existing snake_case conventions (`workspace_id`) where applicable.
- SQL uses `workspaces` and `workspace_id`; source/destination references use `source_workspace_id` / `destination_workspace_id`.
- Public TypeIDs use `ws_` while stored UUIDs remain unchanged.
- REST v1 uses `/api/v1/workspaces`; Web uses `/workspaces`. Old API/Web paths and `vlt_` IDs are rejected without compatibility redirects.
- Identity is the token `sub` / internal `userId`. The former synthetic `workspace_id = personal:…` identity claim and session `workspace` object are removed.
- Server, Web, Desktop and external API/MCP clients must be updated together. This is a pre-release breaking change, not a second API version.

## Desktop data

The published v0.21.0 schema ends at `v41_vaultAISettingsBackfill`. These migrations retain their historical schema and names. The explicitly approved unpublished `v42_localFirstSchema` rebuilds the data once, then renames tables and columns using SQLite. Dependent keys, indexes, triggers and search jobs are updated in the same transaction. A failure rolls back the entire v42 migration.

The migration reads historical rows independently of current Record coding keys. IDs, content, settings, recordings and output paths are preserved. Settings and pending restore requests use Workspace keys without legacy aliases. Backup import accepts format 5 only; formats 2–4 are rejected. Existing export URL schemes and audio storage-location values retain their serialized `vault` value; they are not filesystem relocations.

Old unpublished development/QA v42 databases are not a supported migration source. Never edit the migration ledger to force replay, or reset the normal Application Support database. Development profile replacement is a separate, explicitly scoped operation.

## Server data

Server is unreleased. Its initial SQLite/PostgreSQL schemas create Workspace tables, columns, constraints and policies directly. Existing development Server databases are not migration sources; use a fresh database. There is no Vault rename migration, historical receipt projection or cryptographic domain alias. Ciphertext and wrapped keys use Workspace domains from creation. PostgreSQL runtime support still installs identity functions, FORCE RLS and deferrable membership constraints; SQLite runtime support installs FTS5 and its triggers.

Desktop v41 migration remains data-preserving independently of this Server baseline reset. This change does not reset or modify any actual database.

## Verification

Test fresh databases, v41 upgrades with existing rows, rollback/retry, preserved relationships, current backups and rejection of old backup formats/API IDs. Verify Workspace reads/writes, synchronization, conflicts, sharing and deletion with the existing Server/Desktop suites, including PostgreSQL under a non-superuser without BYPASSRLS.
