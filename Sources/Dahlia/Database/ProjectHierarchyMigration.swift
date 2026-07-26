import DahliaRuntimeSupport
import Foundation
import GRDB

enum ProjectHierarchyMigration {
    fileprivate struct MigratedProject {
        let id: UUID
        let vaultId: UUID
        let path: String
        let createdAt: Date
        let description: String
        let revision: Int
    }

    static func migrate(in db: Database) throws {
        let hasLegacyProjects = try db.tableExists("projects")
        let legacyProjects = hasLegacyProjects ? try MigratedProject.fetchLegacy(in: db) : []
        let migratedProjects = flattenToSupportedDepth(
            disambiguateSiblingNames(projectsIncludingMissingAncestors(legacyProjects))
        )
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

    private static func createProjectsTable(in db: Database) throws {
        let vaultReference = try db.tableExists("vaults")
            ? " REFERENCES vaults(id) ON DELETE CASCADE"
            : ""
        try db.execute(sql: """
        CREATE TABLE projects_v24 (
            id BLOB NOT NULL PRIMARY KEY,
            vaultId BLOB NOT NULL\(vaultReference),
            parentProjectId BLOB,
            name TEXT NOT NULL COLLATE NOCASE,
            nameKey TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            projectType TEXT,
            revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
            UNIQUE(id, vaultId),
            CHECK (
                name = TRIM(name)
                AND LENGTH(name) > 0
                AND name NOT IN ('.', '..')
                AND SUBSTR(name, 1, 1) NOT IN ('.', '_')
                AND INSTR(name, '/') = 0
                AND INSTR(name, ':') = 0
                AND LENGTH(CAST(name AS BLOB)) <= 255
                AND name NOT GLOB ('*[' || char(1) || '-' || char(31) || char(127) || ']*')
            ),
            CHECK (LENGTH(nameKey) > 0),
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
            let name = Self.name(of: project.path)
            let projectType: String? = parentId == nil ? ProjectType.undefined.rawValue : nil

            try db.execute(
                sql: """
                INSERT INTO projects_v24 (
                    id, vaultId, parentProjectId, name, nameKey, createdAt,
                    description, projectType, revision
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    project.id,
                    project.vaultId,
                    parentId,
                    name,
                    DahliaProjectName.siblingKey(name),
                    project.createdAt,
                    project.description,
                    projectType,
                    project.revision,
                ]
            )
        }
    }

    private static func createIndexesAndTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE INDEX projects_on_vaultId ON projects(vaultId);
        CREATE INDEX projects_on_parentProjectId ON projects(parentProjectId);
        CREATE INDEX projects_on_projectType ON projects(projectType);
        CREATE UNIQUE INDEX projects_unique_root_name
            ON projects(vaultId, nameKey)
            WHERE parentProjectId IS NULL;
        CREATE UNIQUE INDEX projects_unique_child_name
            ON projects(parentProjectId, nameKey)
            WHERE parentProjectId IS NOT NULL;

        CREATE TRIGGER projects_validate_parent_insert
        BEFORE INSERT ON projects
        WHEN NEW.parentProjectId IS NOT NULL
        BEGIN
            SELECT RAISE(ABORT, 'project parent must be a root in the same vault')
            WHERE NOT EXISTS (
                SELECT 1 FROM projects
                WHERE id = NEW.parentProjectId
                  AND vaultId = NEW.vaultId
                  AND parentProjectId IS NULL
            );
        END;

        CREATE TRIGGER projects_validate_parent_update
        BEFORE UPDATE OF parentProjectId, vaultId ON projects
        WHEN NEW.parentProjectId IS NOT NULL
        BEGIN
            SELECT RAISE(ABORT, 'project parent must be a root in the same vault')
            WHERE NOT EXISTS (
                SELECT 1 FROM projects
                WHERE id = NEW.parentProjectId
                  AND vaultId = NEW.vaultId
                  AND parentProjectId IS NULL
            ) OR EXISTS (
                SELECT 1 FROM projects WHERE parentProjectId = NEW.id
            );
        END;

        CREATE TRIGGER projects_restrict_parent_delete
        BEFORE DELETE ON projects
        BEGIN
            SELECT RAISE(ABORT, 'project has children')
            WHERE EXISTS (SELECT 1 FROM projects WHERE parentProjectId = OLD.id);
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

    private static func flattenToSupportedDepth(_ projects: [MigratedProject]) -> [MigratedProject] {
        var result: [MigratedProject] = []
        for vaultProjects in Dictionary(grouping: projects, by: \.vaultId).values {
            let directProjects = vaultProjects.filter { $0.path.split(separator: "/").count <= 2 }
            result.append(contentsOf: directProjects)

            var siblingKeys = Dictionary(grouping: directProjects.filter {
                $0.path.split(separator: "/").count == 2
            }, by: {
                $0.path.split(separator: "/").first.map(String.init) ?? $0.path
            }).mapValues { Set($0.map { DahliaProjectName.siblingKey(Self.name(of: $0.path)) }) }

            let deeperProjects = vaultProjects.filter { $0.path.split(separator: "/").count > 2 }
                .sorted {
                    if $0.path != $1.path {
                        return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
            for project in deeperProjects {
                guard let rootPath = project.path.split(separator: "/").first.map(String.init) else {
                    continue
                }
                let safeName = DahliaProjectName.migrationSafeName(Self.name(of: project.path))
                var name = safeName
                var suffix = 2
                while siblingKeys[rootPath, default: []].contains(DahliaProjectName.siblingKey(name)) {
                    name = DahliaProjectName.migrationSafeName(safeName, suffix: " (\(suffix))")
                    suffix += 1
                }
                siblingKeys[rootPath, default: []].insert(DahliaProjectName.siblingKey(name))
                result.append(
                    MigratedProject(
                        id: project.id,
                        vaultId: project.vaultId,
                        path: "\(rootPath)/\(name)",
                        createdAt: project.createdAt,
                        description: project.description,
                        revision: project.revision + 1
                    )
                )
            }
        }
        return result
    }

    private static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func projectsIncludingMissingAncestors(_ projects: [MigratedProject]) -> [MigratedProject] {
        var result = Dictionary(
            uniqueKeysWithValues: projects.map {
                (VaultPath(vaultId: $0.vaultId, path: $0.path), $0)
            }
        )

        for project in projects {
            for path in intermediatePaths(for: project.path).dropLast() {
                let key = VaultPath(vaultId: project.vaultId, path: path)
                guard result[key] == nil else { continue }
                result[key] = MigratedProject(
                    id: .v7(),
                    vaultId: project.vaultId,
                    path: path,
                    createdAt: project.createdAt,
                    description: "",
                    revision: 1
                )
            }
        }

        return Array(result.values)
    }

    /// Legacy binary uniqueness allowed case and Unicode-equivalent siblings. Keep every UUID and
    /// deterministically disambiguate only the canonical name so v24 can always start.
    private static func disambiguateSiblingNames(_ projects: [MigratedProject]) -> [MigratedProject] {
        var adjustedPathByOriginal: [VaultPath: String] = [:]
        var siblingKeys: [VaultPath: Set<String>] = [:]
        var result: [MigratedProject] = []

        for project in projects.sorted(by: sortByDepth) {
            let originalParentPath = parentPath(of: project.path)
            let adjustedParentPath = originalParentPath.flatMap {
                adjustedPathByOriginal[VaultPath(vaultId: project.vaultId, path: $0)]
            }
            let parentKey = VaultPath(vaultId: project.vaultId, path: adjustedParentPath ?? "")
            let originalName = name(of: project.path)
            let safeName = DahliaProjectName.migrationSafeName(originalName)
            var adjustedName = safeName
            var suffix = 2
            while siblingKeys[parentKey, default: []].contains(DahliaProjectName.siblingKey(adjustedName)) {
                adjustedName = DahliaProjectName.migrationSafeName(safeName, suffix: " (\(suffix))")
                suffix += 1
            }
            siblingKeys[parentKey, default: []].insert(DahliaProjectName.siblingKey(adjustedName))
            let adjustedPath = adjustedParentPath.map { "\($0)/\(adjustedName)" } ?? adjustedName
            adjustedPathByOriginal[VaultPath(vaultId: project.vaultId, path: project.path)] = adjustedPath
            result.append(
                MigratedProject(
                    id: project.id,
                    vaultId: project.vaultId,
                    path: adjustedPath,
                    createdAt: project.createdAt,
                    description: project.description,
                    revision: project.revision
                )
            )
        }
        return result
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

}

private extension ProjectHierarchyMigration.MigratedProject {
    static func fetchLegacy(in db: Database) throws -> [Self] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT id, vaultId, name, createdAt, description
            FROM projects
            """
        ).map { row in
            Self(
                id: row["id"],
                vaultId: row["vaultId"],
                path: row["name"],
                createdAt: row["createdAt"],
                description: row["description"],
                revision: 1
            )
        }
    }
}
