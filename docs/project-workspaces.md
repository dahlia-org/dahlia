# Project workspaces

Dahlia Projects are workspaces for organizing meetings. A root can represent a customer, an internal activity, a
personal activity, or an unclassified activity. Projects are not limited to customer engagements, and a customer root
can gain subprojects as parallel engagements appear.

## Canonical hierarchy

The database is the sole canonical source for Project identity and hierarchy:

- `projects.id` is the stable Project identity.
- `projects.vaultId` fixes a Project to one Vault.
- `projects.parentProjectId` is `NULL` for a root and otherwise identifies a parent in the same Vault.
- `projects.name` is one logical path component.
- `projects.nameKey` is an internal, materialized Unicode-normalized and case-folded sibling identity. Application,
  migration, and MCP writes compute it through the shared `DahliaProjectName` contract; raw SQL is not a supported
  mutation interface.
- A Project path is derived by following parent IDs and joining names.

Project nesting is limited to one subproject level:

```text
Vault
└── Root Project
    └── Subproject
```

A subproject can only name a root in the same Vault as its parent and cannot have children. A root with children cannot
become a subproject. A childless root can become a subproject, and a subproject can move either to another root or to the
Vault root. Database constraints, repository/service validation, UI choices, and MCP validation enforce the same limit.
Sibling names, including root names, are unique by `nameKey`. Rename and reparent preserve Project UUIDs.

Project identity and `parentProjectId` are deliberately independent from future Organization or Person relationships.
Those tables may later reference stable Project IDs, but neither is a Project hierarchy parent.

## Project type

`projectType` has four values: `customer`, `internal`, `personal`, and `undefined`.

Only a root stores a non-null explicit value. A subproject stores `NULL` and resolves its effective value from its root.
Read models expose the explicit value, effective value, type-owning root Project ID, and whether the value is inherited.

- Changing a root type changes every subproject's effective type.
- Moving a subproject under another root makes it inherit the new root.
- Moving a subproject to the Vault root copies its previous effective type into its new explicit value.
- Moving a root under another Project clears its previous explicit value.
- Directly setting a subproject type is an error.

## Derived Summary output directories

The logical Project path determines a desired Summary output directory below the Vault path. This is a one-way
derivation:

```text
Project records in SQLite
        ↓
Vault-relative Summary output directory
```

Creating a Project does not create a directory. Dahlia creates the necessary output directory lazily when a Summary
file must be written or moved there. A directory's presence, absence, name, or position never creates, renames,
reparents, deletes, or identifies a Project. Finder and external-tool changes are not reverse-synchronized into the
Project tree, and intermediate directories found on disk are not Projects.

Rename and reparent relocate only tracked Vault Summary files whose stored paths already live below the affected
Project's old derived path. A valid legacy or explicitly retained Summary path outside that derived path remains where
it is. Missing tracked files clear their stale export records. Project operations do not rename, move, or delete whole
directories; unrelated files and now-empty directories are retained. Vault filesystem events may keep tracked Summary
export paths current or clear them when the tracked files disappear, but they never mutate Project records.

Before moving a Summary, Dahlia rejects case-insensitive destination collisions, non-directory path components,
symlinks in the destination chain, paths that resolve outside the Vault, and a source file still referenced by a
retained export. A missing derived directory is a normal state, not a Project health error. Regenerating a tracked
Summary may overwrite that Meeting's stored file; a new export never overwrites an existing file and uses a stable
Meeting UUID suffix when its preferred filename is already occupied.

## Workspace mutations

Create validates the root-or-subproject parent contract and sibling uniqueness, then inserts only the Project record.
Rename and reparent update one canonical parent/name relation and increment revisions for Projects whose
derived path or effective type changed. Project type transitions follow the rules above. Meeting membership changes
move tracked Vault Summary files into the destination Project's derived directory and update their export records.
Summary generation resolves the Meeting's current membership and Project path again while holding the same Vault lock,
so a concurrent rename, reparent, or membership update cannot restore an obsolete output path.

SQLite and filesystem operations cannot share one native transaction. Dahlia therefore uses a Vault-scoped advisory
lock, prevalidates the complete Summary move, creates only required output directories, performs file moves, commits one
database transaction, and compensates file moves and newly created empty directories if the database commit fails.
Project deletion stages managed audio before its database transaction and restores it on commit failure. Deletion keeps
Project output directories and unrelated files; the UI can optionally move tracked Summary files to the Trash when it
also deletes the Meetings. A rollback failure is reported explicitly.

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
move to the Vault root. Project creation and rename use `name`; callers never submit a path. Meeting membership
batches require an expected current Project ID, including explicit `null`, for every Meeting. One stale expectation
rejects the entire batch. Every MCP process can read only its fixed Vault; write-enabled processes can mutate only that
Vault, use the same Vault mutation lock as the app, and notify the running app after commits.

Project deletion and merge are not exposed through MCP. A future design must define Meeting relocation, non-empty and
missing output directories, Summary handling, and recovery before adding those tools. Organization/Person associations
and changes to Vault identity or setup are also outside this Project change.

## Migration

The single hierarchy migration retains existing Project UUIDs, descriptions, creation dates, and same-Vault Meeting
memberships. It converts legacy slash-delimited paths into stable parent/name records and moves every Project
below the supported subproject level directly under its original root before installing the bounded-hierarchy
constraints. If flattening creates a sibling-name collision, Dahlia adds a deterministic numeric suffix. Moved records
increment their revisions and inherit their root type.

Migration does not move existing Summary files merely to match a newly flattened logical path. Their stored
Vault-relative locations remain valid legacy locations until a later Meeting membership operation moves them. The
legacy `googleDriveFolderId`, `missingOnDisk`, and `legacyContextMigrated` columns are omitted from the rebuilt table;
their values are intentionally discarded. Existing `CONTEXT.md` files are not read, migrated, or removed.
