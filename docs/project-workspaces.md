# Project workspaces

Dahlia Projects are workspaces for organizing meetings. A root can represent a customer, an internal activity, a
personal activity, or an unclassified activity. Projects are not limited to customer engagements, and a customer root
can gain subprojects as parallel engagements appear.

## Canonical hierarchy and directories

The database is canonical for identity and hierarchy:

- `projects.id` is the stable Project identity.
- `projects.vaultId` fixes a Project to one Vault.
- `projects.parentProjectId` is `NULL` for a root and otherwise identifies a parent in the same Vault.
- `projects.leafName` is one directory component.
- `projects.leafNameKey` is an internal, materialized Unicode-normalized and case-folded sibling identity. Application,
  sync, migration, and MCP writes compute it through the shared `DahliaProjectName` contract; raw SQL is not a supported
  Project mutation interface.
- A Project path is derived by following parent IDs and joining leaf names.

The derived path maps one-to-one to a directory below the Vault. Paths are not stored as a second canonical hierarchy.
The database rejects missing or cross-Vault parents, cycles, self-parenting, and case-insensitive duplicate sibling
names. Rename and reparent keep every Project UUID.

Vault synchronization creates Projects for intermediate directories discovered on disk. A missing directory retains
the Project row and UUID with `missingOnDisk = true`; it does not silently delete metadata. A paired Finder
rename/reparent event preserves the UUID when Dahlia can correlate its source and destination. An offline or ambiguous
move may instead appear as a missing Project plus a newly discovered directory because directories do not contain hidden
Dahlia identity files. Stable identity is guaranteed for app and MCP rename/reparent operations.

## Project type

`projectType` has four values: `customer`, `internal`, `personal`, and `undefined`.

Only a root stores a non-null explicit value. A child stores `NULL` and resolves its effective value from its root.
Read models expose the explicit value, effective value, type-owning root Project ID, and whether the value is inherited.

- Changing a root type changes every descendant's effective type.
- Moving a subtree under another root makes it inherit the new root.
- Moving a child to the Vault root copies its previous effective type into its new explicit value.
- Moving a root under another Project clears its previous explicit value.
- Directly setting a child type is an error.

## Workspace mutations

Create validates the parent and destination before creating one directory. Rename and reparent validate sibling and
filesystem collisions, move the directory, update the parent/leaf relation, increment revisions for affected Projects,
and rewrite Vault Summary export path prefixes. Meeting membership changes move Vault Summary files and update their
export records. A missing Summary file clears its stale Vault export record.

SQLite and filesystem operations cannot share one native transaction. Dahlia therefore uses a Vault-scoped advisory
lock, prevalidates the complete operation, performs filesystem moves, commits one database transaction, and compensates
filesystem moves if the database commit fails. Project deletion stages managed audio before its database transaction
and restores it on commit failure. A rollback failure is reported explicitly. Symlink-resolved paths outside the Vault
and symlink components within Project paths are rejected.

Meeting–Project is an exclusive membership: a Meeting has zero or one `projectId`. It is intentionally named
“membership” in MCP and must not be confused with a possible future many-to-many link.

## MCP contract

`dahlia-mcp --vault-id <UUID>` is read-only. Adding the sole capability flag, `--write`, publishes update tools. A
meeting-limited MCP process cannot combine `--meeting-id` with `--write`.
Full-Vault in-app chat starts the helper with `--write`; meeting-limited summary sessions remain read-only.

Read tools:

- `query_projects`
- `get_project`
- `query_meetings`
- `get_meeting`
- `get_meeting_transcript`
- `get_meeting_screenshots`

Write tools:

- `create_project`
- `update_project`
- `set_meeting_project_memberships`

Project updates require the current `revision`. Omitted JSON properties are unchanged; `parent_project_id: null` means
move to the Vault root. Meeting membership batches require an expected current Project ID, including explicit `null`,
for every Meeting. One stale expectation rejects the entire batch. MCP processes can read and mutate only their fixed
Vault, use the same Vault mutation lock as the app, and notify the running app after commits.

Project deletion and merge are not exposed through MCP. A future design must define Meeting relocation, non-empty and
missing directories, Summary handling, and recovery before adding those tools.
