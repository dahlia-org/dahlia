import DahliaRuntimeSupport
import Foundation
import GRDB

enum ProjectHierarchyMigration {
    fileprivate struct MigratedProject {
        let id: UUID
        let vaultId: UUID
        let path: String
        let createdAt: Date
        let googleDriveFolderId: String?
        let missingOnDisk: Bool
        let description: String
        let legacyContextMigrated: Bool
    }

    static func migrate(in db: Database) throws {
        let hasLegacyProjects = try db.tableExists("projects")
        let legacyProjects = hasLegacyProjects ? try MigratedProject.fetchLegacy(in: db) : []
        let disambiguation = disambiguateSiblingNames(projectsIncludingMissingAncestors(legacyProjects))
        let migratedProjects = disambiguation.projects
        let preservesMeetingMemberships = hasLegacyProjects ? try db.tableExists("meetings") : false

        try createProjectsTable(in: db)
        try insert(migratedProjects, in: db)
        if preservesMeetingMemberships {
            try preserveMeetingMemberships(in: db)
        }
        if hasLegacyProjects {
            try db.drop(table: "projects")
        }
        try db.rename(table: "projects_v24", to: "projects")
        if preservesMeetingMemberships {
            try restoreMeetingMemberships(in: db)
            try repairSummaryExportPaths(disambiguation.pathByOriginal, in: db)
        }
        try createIndexesAndTriggers(in: db)
        if try db.tableExists("vaults") {
            try createVaultTriggers(in: db)
        }
        if try db.tableExists("meetings") {
            try createMeetingTriggers(in: db)
        }
    }

    /// Dropping the legacy projects table applies meetings.projectId's ON DELETE SET NULL action.
    /// Preserve those exclusive memberships across the table rebuild.
    private static func preserveMeetingMemberships(in db: Database) throws {
        try db.execute(sql: """
        CREATE TEMP TABLE project_memberships_v24 (
            meetingId BLOB NOT NULL PRIMARY KEY,
            projectId BLOB NOT NULL
        );
        INSERT INTO project_memberships_v24 (meetingId, projectId)
        SELECT id, projectId
        FROM meetings
        WHERE projectId IS NOT NULL;
        """)
    }

    private static func restoreMeetingMemberships(in db: Database) throws {
        try db.execute(sql: """
        UPDATE meetings
        SET projectId = (
            SELECT project_memberships_v24.projectId
            FROM project_memberships_v24
            JOIN projects
              ON projects.id = project_memberships_v24.projectId
             AND projects.vaultId = meetings.vaultId
            WHERE project_memberships_v24.meetingId = meetings.id
        )
        WHERE id IN (SELECT meetingId FROM project_memberships_v24);
        DROP TABLE project_memberships_v24;
        """)
    }

    private static func repairSummaryExportPaths(
        _ pathByOriginal: [VaultPath: String],
        in db: Database
    ) throws {
        guard try db.tableExists("summary_exports") else { return }
        let changedPaths = pathByOriginal.filter { $0.key.path != $0.value }
        guard !changedPaths.isEmpty else { return }

        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT summary_exports.meetingId, summary_exports.url, meetings.vaultId
            FROM summary_exports
            JOIN meetings ON meetings.id = summary_exports.meetingId
            WHERE summary_exports.type = ?
            """,
            arguments: [SummaryExportType.vault]
        )
        for row in rows {
            let meetingID: UUID = row["meetingId"]
            let vaultID: UUID = row["vaultId"]
            let url: String = row["url"]
            guard let relativePath = SummaryExportRecord(
                meetingId: meetingID,
                type: .vault,
                url: url,
                createdAt: .distantPast,
                updatedAt: .distantPast
            ).vaultRelativePath else { continue }

            let match = changedPaths
                .filter {
                    $0.key.vaultId == vaultID
                        && (relativePath == $0.key.path || relativePath.hasPrefix($0.key.path + "/"))
                }
                .max { $0.key.path.utf8.count < $1.key.path.utf8.count }
            guard let match,
                  let repairedURL = SummaryExportRecord.vaultURL(
                      relativePath: match.value + relativePath.dropFirst(match.key.path.count)
                  ) else { continue }
            try db.execute(
                sql: """
                UPDATE summary_exports
                SET url = ?, updatedAt = ?
                WHERE meetingId = ? AND type = ?
                """,
                arguments: [repairedURL, Date.now, meetingID, SummaryExportType.vault]
            )
        }
    }

    private static func createProjectsTable(in db: Database) throws {
        let vaultReference = try db.tableExists("vaults")
            ? " REFERENCES vaults(id) ON DELETE CASCADE"
            : ""
        try db.execute(sql: """
        CREATE TABLE projects_v24 (
            id BLOB NOT NULL PRIMARY KEY,
            vaultId BLOB NOT NULL\(vaultReference),
            parentProjectId BLOB,
            leafName TEXT NOT NULL COLLATE NOCASE,
            leafNameKey TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            googleDriveFolderId TEXT,
            missingOnDisk BOOLEAN NOT NULL DEFAULT 0,
            description TEXT NOT NULL DEFAULT '',
            legacyContextMigrated BOOLEAN NOT NULL DEFAULT 0,
            projectType TEXT,
            revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
            UNIQUE(id, vaultId),
            CHECK (
                leafName = TRIM(leafName)
                AND LENGTH(leafName) > 0
                AND leafName NOT IN ('.', '..')
                AND SUBSTR(leafName, 1, 1) NOT IN ('.', '_')
                AND INSTR(leafName, '/') = 0
                AND INSTR(leafName, ':') = 0
                AND LENGTH(CAST(leafName AS BLOB)) <= 255
                AND leafName NOT GLOB ('*[' || char(1) || '-' || char(31) || char(127) || ']*')
            ),
            CHECK (LENGTH(leafNameKey) > 0),
            CHECK (
                (
                    parentProjectId IS NULL
                    AND projectType IS NOT NULL
                    AND projectType IN ('customer', 'internal', 'personal', 'undefined')
                )
                OR (parentProjectId IS NOT NULL AND projectType IS NULL)
            ),
            CHECK (parentProjectId IS NULL OR parentProjectId <> id)
        )
        """)
    }

    private static func insert(_ projects: [MigratedProject], in db: Database) throws {
        let idsByVaultAndPath = Dictionary(
            uniqueKeysWithValues: projects.map { (VaultPath(vaultId: $0.vaultId, path: $0.path), $0.id) }
        )

        for project in projects.sorted(by: Self.sortByDepth) {
            let parentPath = parentPath(of: project.path)
            let parentId = parentPath.flatMap { idsByVaultAndPath[VaultPath(vaultId: project.vaultId, path: $0)] }
            let leafName = project.path.split(separator: "/").last.map(String.init) ?? project.path
            let projectType: String? = parentId == nil ? ProjectType.undefined.rawValue : nil

            try db.execute(
                sql: """
                INSERT INTO projects_v24 (
                    id, vaultId, parentProjectId, leafName, leafNameKey, createdAt, googleDriveFolderId,
                    missingOnDisk, description, legacyContextMigrated, projectType, revision
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """,
                arguments: [
                    project.id,
                    project.vaultId,
                    parentId,
                    leafName,
                    DahliaProjectName.siblingKey(leafName),
                    project.createdAt,
                    project.googleDriveFolderId,
                    project.missingOnDisk,
                    project.description,
                    project.legacyContextMigrated,
                    projectType,
                ]
            )
        }
    }

    private static func createIndexesAndTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE INDEX projects_on_vaultId ON projects(vaultId);
        CREATE INDEX projects_on_parentProjectId ON projects(parentProjectId);
        CREATE INDEX projects_on_projectType ON projects(projectType);
        CREATE UNIQUE INDEX projects_unique_root_leaf
            ON projects(vaultId, leafNameKey)
            WHERE parentProjectId IS NULL;
        CREATE UNIQUE INDEX projects_unique_child_leaf
            ON projects(parentProjectId, leafNameKey)
            WHERE parentProjectId IS NOT NULL;

        CREATE TRIGGER projects_validate_parent_insert
        BEFORE INSERT ON projects
        WHEN NEW.parentProjectId IS NOT NULL
        BEGIN
            SELECT RAISE(ABORT, 'project parent belongs to another vault or does not exist')
            WHERE NOT EXISTS (
                SELECT 1 FROM projects
                WHERE id = NEW.parentProjectId AND vaultId = NEW.vaultId
            );
        END;

        CREATE TRIGGER projects_validate_parent_update
        BEFORE UPDATE OF parentProjectId, vaultId ON projects
        WHEN NEW.parentProjectId IS NOT NULL
        BEGIN
            SELECT RAISE(ABORT, 'project parent belongs to another vault or does not exist')
            WHERE NOT EXISTS (
                SELECT 1 FROM projects
                WHERE id = NEW.parentProjectId AND vaultId = NEW.vaultId
            );
        END;

        CREATE TRIGGER projects_restrict_parent_delete
        BEFORE DELETE ON projects
        BEGIN
            SELECT RAISE(ABORT, 'project has children')
            WHERE EXISTS (SELECT 1 FROM projects WHERE parentProjectId = OLD.id);
        END;

        CREATE TRIGGER projects_prevent_cycles
        BEFORE UPDATE OF parentProjectId ON projects
        WHEN NEW.parentProjectId IS NOT NULL
        BEGIN
            WITH RECURSIVE ancestors(id, parentProjectId) AS (
                SELECT id, parentProjectId
                FROM projects
                WHERE id = NEW.parentProjectId AND vaultId = NEW.vaultId
                UNION ALL
                SELECT projects.id, projects.parentProjectId
                FROM projects
                JOIN ancestors ON projects.id = ancestors.parentProjectId
                WHERE projects.vaultId = NEW.vaultId
            )
            SELECT RAISE(ABORT, 'project hierarchy cycle')
            WHERE EXISTS (SELECT 1 FROM ancestors WHERE id = NEW.id);
        END;

        CREATE TRIGGER projects_prevent_vault_change
        BEFORE UPDATE OF vaultId ON projects
        WHEN NEW.vaultId <> OLD.vaultId
        BEGIN
            SELECT RAISE(ABORT, 'project vault is immutable');
        END;

        """)
    }

    private static func createMeetingTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER meetings_validate_project_vault_insert
        BEFORE INSERT ON meetings
        WHEN NEW.projectId IS NOT NULL
        BEGIN
            SELECT RAISE(ABORT, 'meeting project belongs to another vault')
            WHERE NOT EXISTS (
                SELECT 1 FROM projects
                WHERE projects.id = NEW.projectId AND projects.vaultId = NEW.vaultId
            );
        END;

        CREATE TRIGGER meetings_validate_project_vault_update
        BEFORE UPDATE OF projectId, vaultId ON meetings
        WHEN NEW.projectId IS NOT NULL
        BEGIN
            SELECT RAISE(ABORT, 'meeting project belongs to another vault')
            WHERE NOT EXISTS (
                SELECT 1 FROM projects
                WHERE projects.id = NEW.projectId AND projects.vaultId = NEW.vaultId
            );
        END;
        """)
    }

    private static func createVaultTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER projects_validate_vault_insert
        BEFORE INSERT ON projects
        BEGIN
            SELECT RAISE(ABORT, 'project vault does not exist')
            WHERE NOT EXISTS (SELECT 1 FROM vaults WHERE id = NEW.vaultId);
        END;
        """)
    }

    private static func projectsIncludingMissingAncestors(_ projects: [MigratedProject]) -> [MigratedProject] {
        let legacyKeys = Set(projects.map { VaultPath(vaultId: $0.vaultId, path: $0.path) })
        var result = Dictionary(
            uniqueKeysWithValues: projects.map {
                (VaultPath(vaultId: $0.vaultId, path: $0.path), $0)
            }
        )

        for project in projects {
            for path in intermediatePaths(for: project.path).dropLast() {
                let key = VaultPath(vaultId: project.vaultId, path: path)
                if let existing = result[key] {
                    guard !legacyKeys.contains(key), existing.missingOnDisk, !project.missingOnDisk else {
                        continue
                    }
                    result[key] = MigratedProject(
                        id: existing.id,
                        vaultId: existing.vaultId,
                        path: existing.path,
                        createdAt: existing.createdAt,
                        googleDriveFolderId: existing.googleDriveFolderId,
                        missingOnDisk: false,
                        description: existing.description,
                        legacyContextMigrated: existing.legacyContextMigrated
                    )
                    continue
                }
                result[key] = MigratedProject(
                    id: .v7(),
                    vaultId: project.vaultId,
                    path: path,
                    createdAt: project.createdAt,
                    googleDriveFolderId: nil,
                    missingOnDisk: project.missingOnDisk,
                    description: "",
                    legacyContextMigrated: true
                )
            }
        }

        return Array(result.values)
    }

    /// Legacy binary uniqueness allowed case and Unicode-equivalent siblings. Keep every UUID and
    /// deterministically disambiguate only the canonical leaf name so v24 can always start.
    private static func disambiguateSiblingNames(_ projects: [MigratedProject]) -> Disambiguation {
        var adjustedPathByOriginal: [VaultPath: String] = [:]
        var siblingKeys: [VaultPath: Set<String>] = [:]
        var result: [MigratedProject] = []

        for project in projects.sorted(by: sortByDepth) {
            let originalParentPath = parentPath(of: project.path)
            let adjustedParentPath = originalParentPath.flatMap {
                adjustedPathByOriginal[VaultPath(vaultId: project.vaultId, path: $0)]
            }
            let parentKey = VaultPath(vaultId: project.vaultId, path: adjustedParentPath ?? "")
            let originalLeaf = project.path.split(separator: "/").last.map(String.init) ?? project.path
            let safeLeaf = DahliaProjectName.migrationSafeLeafName(originalLeaf)
            var leaf = safeLeaf
            var suffix = 2
            while siblingKeys[parentKey, default: []].contains(DahliaProjectName.siblingKey(leaf)) {
                leaf = DahliaProjectName.migrationSafeLeafName(safeLeaf, suffix: " (\(suffix))")
                suffix += 1
            }
            siblingKeys[parentKey, default: []].insert(DahliaProjectName.siblingKey(leaf))
            let adjustedPath = adjustedParentPath.map { "\($0)/\(leaf)" } ?? leaf
            adjustedPathByOriginal[VaultPath(vaultId: project.vaultId, path: project.path)] = adjustedPath
            result.append(
                MigratedProject(
                    id: project.id,
                    vaultId: project.vaultId,
                    path: adjustedPath,
                    createdAt: project.createdAt,
                    googleDriveFolderId: project.googleDriveFolderId,
                    missingOnDisk: project.missingOnDisk || leaf != originalLeaf,
                    description: project.description,
                    legacyContextMigrated: project.legacyContextMigrated
                )
            )
        }
        return Disambiguation(projects: result, pathByOriginal: adjustedPathByOriginal)
    }

    private static func intermediatePaths(for path: String) -> [String] {
        let components = path.split(separator: "/")
        return components.indices.map { index in
            components[...index].joined(separator: "/")
        }
    }

    private static func parentPath(of path: String) -> String? {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    private static func sortByDepth(_ lhs: MigratedProject, _ rhs: MigratedProject) -> Bool {
        let lhsDepth = lhs.path.split(separator: "/").count
        let rhsDepth = rhs.path.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        if lhs.vaultId != rhs.vaultId { return lhs.vaultId.uuidString < rhs.vaultId.uuidString }
        if lhs.path != rhs.path {
            return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private struct VaultPath: Hashable {
        let vaultId: UUID
        let path: String
    }

    private struct Disambiguation {
        let projects: [MigratedProject]
        let pathByOriginal: [VaultPath: String]
    }
}

private extension ProjectHierarchyMigration.MigratedProject {
    static func fetchLegacy(in db: Database) throws -> [Self] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT id, vaultId, name, createdAt, googleDriveFolderId, missingOnDisk,
                   description, legacyContextMigrated
            FROM projects
            """
        ).map { row in
            Self(
                id: row["id"],
                vaultId: row["vaultId"],
                path: row["name"],
                createdAt: row["createdAt"],
                googleDriveFolderId: row["googleDriveFolderId"],
                missingOnDisk: row["missingOnDisk"],
                description: row["description"],
                legacyContextMigrated: row["legacyContextMigrated"]
            )
        }
    }
}
