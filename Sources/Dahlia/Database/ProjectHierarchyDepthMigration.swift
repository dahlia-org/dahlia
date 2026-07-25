import DahliaRuntimeSupport
import Foundation
import GRDB

enum ProjectHierarchyDepthMigration {
    private struct Project {
        let id: UUID
        let vaultId: UUID
        let parentId: UUID?
        let leafName: String
        let revision: Int
    }

    static func migrate(in db: Database) throws {
        let projects = try Row.fetchAll(
            db,
            sql: "SELECT id, vaultId, parentProjectId, leafName, revision FROM projects"
        ).map { row in
            Project(
                id: row["id"],
                vaultId: row["vaultId"],
                parentId: row["parentProjectId"],
                leafName: row["leafName"],
                revision: row["revision"]
            )
        }

        for vaultProjects in Dictionary(grouping: projects, by: \.vaultId).values {
            try flatten(vaultProjects, in: db)
        }
        try db.execute(sql: "UPDATE projects SET missingOnDisk = 0 WHERE missingOnDisk <> 0")
        try replaceParentTriggers(in: db)
    }

    private static func flatten(_ projects: [Project], in db: Database) throws {
        let byId = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        func ancestry(for project: Project) -> [Project] {
            var result = [project]
            var current = project
            var visited: Set<UUID> = [project.id]
            while let parentId = current.parentId,
                  let parent = byId[parentId],
                  visited.insert(parent.id).inserted {
                result.append(parent)
                current = parent
            }
            return result.reversed()
        }

        let ancestryById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, ancestry(for: $0)) })
        let moving = projects.filter { (ancestryById[$0.id]?.count ?? 1) > 2 }
            .sorted {
                let lhsPath = ancestryById[$0.id, default: []].map(\.leafName).joined(separator: "/")
                let rhsPath = ancestryById[$1.id, default: []].map(\.leafName).joined(separator: "/")
                if lhsPath != rhsPath {
                    return lhsPath.utf8.lexicographicallyPrecedes(rhsPath.utf8)
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        var siblingKeys = Dictionary(grouping: projects.filter {
            (ancestryById[$0.id]?.count ?? 1) <= 2 && $0.parentId != nil
        }, by: \.parentId).mapValues { Set($0.map { DahliaProjectName.siblingKey($0.leafName) }) }

        for project in moving {
            guard let root = ancestryById[project.id]?.first else { continue }
            let parentId = root.id
            let safeLeaf = DahliaProjectName.migrationSafeLeafName(project.leafName)
            var leafName = safeLeaf
            var suffix = 2
            while siblingKeys[parentId, default: []].contains(DahliaProjectName.siblingKey(leafName)) {
                leafName = DahliaProjectName.migrationSafeLeafName(safeLeaf, suffix: " (\(suffix))")
                suffix += 1
            }
            siblingKeys[parentId, default: []].insert(DahliaProjectName.siblingKey(leafName))
            try db.execute(
                sql: """
                UPDATE projects
                SET parentProjectId = ?, leafName = ?, leafNameKey = ?,
                    projectType = NULL, revision = ?
                WHERE id = ?
                """,
                arguments: [
                    parentId,
                    leafName,
                    DahliaProjectName.siblingKey(leafName),
                    project.revision + 1,
                    project.id,
                ]
            )
        }
    }

    private static func replaceParentTriggers(in db: Database) throws {
        try db.execute(sql: """
        DROP TRIGGER IF EXISTS projects_validate_parent_insert;
        DROP TRIGGER IF EXISTS projects_validate_parent_update;

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
        """)
    }
}
