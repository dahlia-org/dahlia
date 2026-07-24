import DahliaRuntimeSupport
import Foundation
import GRDB

/// A stable Project entity. The canonical hierarchy is parentProjectId + leafName.
struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "projects"

    var id: UUID
    var vaultId: UUID
    var parentProjectId: UUID?
    var leafName: String {
        didSet {
            leafNameKey = DahliaProjectName.siblingKey(leafName)
        }
    }

    var leafNameKey: String
    var createdAt: Date
    var description = ""
    var missingOnDisk = false
    var projectType: ProjectType?
    var revision = 1

    /// Populated by hierarchy-aware repository reads. It is never persisted.
    var resolvedPath: String?

    var name: String {
        resolvedPath ?? leafName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case vaultId
        case parentProjectId
        case leafName
        case leafNameKey
        case createdAt
        case description
        case missingOnDisk
        case projectType
        case revision
    }

    init(
        id: UUID,
        vaultId: UUID,
        parentProjectId: UUID?,
        leafName: String,
        createdAt: Date,
        description: String = "",
        missingOnDisk: Bool = false,
        projectType: ProjectType?,
        revision: Int = 1,
        resolvedPath: String? = nil
    ) {
        self.id = id
        self.vaultId = vaultId
        self.parentProjectId = parentProjectId
        self.leafName = leafName
        leafNameKey = DahliaProjectName.siblingKey(leafName)
        self.createdAt = createdAt
        self.description = description
        self.missingOnDisk = missingOnDisk
        self.projectType = projectType
        self.revision = revision
        self.resolvedPath = resolvedPath
    }

    /// Compatibility initializer for call sites that construct a root or an in-memory path fixture.
    init(
        id: UUID,
        vaultId: UUID,
        name: String,
        createdAt: Date,
        description: String = "",
        missingOnDisk: Bool = false
    ) {
        self.init(
            id: id,
            vaultId: vaultId,
            parentProjectId: nil,
            leafName: name.split(separator: "/").last.map(String.init) ?? name,
            createdAt: createdAt,
            description: description,
            missingOnDisk: missingOnDisk,
            projectType: .undefined,
            resolvedPath: name
        )
    }

    static func fetchResolved(id: UUID, in db: Database) throws -> ProjectRecord? {
        guard let record = try fetchOne(db, key: id) else { return nil }
        return try fetchResolvedAll(vaultId: record.vaultId, in: db).first { $0.id == id }
    }

    static func fetchResolvedAll(vaultId: UUID, in db: Database) throws -> [ProjectRecord] {
        var records = try ProjectRecord
            .filter(Column("vaultId") == vaultId)
            .fetchAll(db)
        let paths = resolvedPaths(records)
        for index in records.indices {
            records[index].resolvedPath = paths[records[index].id]
        }
        return records.sorted {
            if $0.name == $1.name { return $0.id.uuidString < $1.id.uuidString }
            return $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
        }
    }

    static func resolvedPaths(_ records: [ProjectRecord]) -> [UUID: String] {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var paths: [UUID: String] = [:]

        func resolve(_ record: ProjectRecord, visiting: Set<UUID>) -> String {
            if let path = paths[record.id] { return path }
            guard let parentProjectId = record.parentProjectId,
                  let parent = recordsByID[parentProjectId],
                  !visiting.contains(parentProjectId)
            else {
                paths[record.id] = record.leafName
                return record.leafName
            }
            let parentPath = resolve(parent, visiting: visiting.union([record.id]))
            let path = "\(parentPath)/\(record.leafName)"
            paths[record.id] = path
            return path
        }

        for record in records {
            _ = resolve(record, visiting: [])
        }
        return paths
    }

    static func hierarchy(projectId: UUID, vaultId: UUID, in db: Database) throws -> [ProjectRecord] {
        let records = try fetchResolvedAll(vaultId: vaultId, in: db)
        return hierarchy(projectId: projectId, records: records)
    }

    static func hierarchy(path: String, vaultId: UUID, in db: Database) throws -> [ProjectRecord] {
        let records = try fetchResolvedAll(vaultId: vaultId, in: db)
        guard let project = records.first(where: { $0.name == path }) else { return [] }
        return hierarchy(projectId: project.id, records: records)
    }

    private static func hierarchy(projectId: UUID, records: [ProjectRecord]) -> [ProjectRecord] {
        let childrenByParent = Dictionary(grouping: records, by: \.parentProjectId)
        var result: [ProjectRecord] = []

        func append(_ project: ProjectRecord) {
            result.append(project)
            for child in childrenByParent[project.id, default: []] {
                append(child)
            }
        }

        guard let root = records.first(where: { $0.id == projectId }) else { return [] }
        append(root)
        return result
    }

    static func effectiveType(
        for projectId: UUID,
        records: [ProjectRecord]
    ) -> (type: ProjectType, ownerProjectId: UUID)? {
        effectiveTypes(records)[projectId]
    }

    static func effectiveTypes(
        _ records: [ProjectRecord]
    ) -> [UUID: (type: ProjectType, ownerProjectId: UUID)] {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var result: [UUID: (type: ProjectType, ownerProjectId: UUID)] = [:]

        func resolve(
            _ project: ProjectRecord,
            visiting: Set<UUID>
        ) -> (type: ProjectType, ownerProjectId: UUID)? {
            if let effectiveType = result[project.id] { return effectiveType }
            guard !visiting.contains(project.id) else { return nil }
            let effectiveType: (type: ProjectType, ownerProjectId: UUID)? = if let parentID = project.parentProjectId,
                                                                               let parent = recordsByID[parentID] {
                resolve(parent, visiting: visiting.union([project.id]))
            } else {
                (project.projectType ?? .undefined, project.id)
            }
            result[project.id] = effectiveType
            return effectiveType
        }

        for record in records {
            _ = resolve(record, visiting: [])
        }
        return result
    }

    /// Synchronizes all intermediate directory paths without making paths canonical DB state.
    static func upsertAll(paths: [String], vaultId: UUID, in db: Database) throws {
        var records = try fetchResolvedAll(vaultId: vaultId, in: db)
        var idByPath = Dictionary(uniqueKeysWithValues: records.map { (pathKey($0.name), $0.id) })
        var indexByID = Dictionary(uniqueKeysWithValues: records.indices.map { (records[$0].id, $0) })

        let allPaths = Set(paths.flatMap(allIntermediatePaths))
            .sorted {
                let lhsDepth = $0.split(separator: "/").count
                let rhsDepth = $1.split(separator: "/").count
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                return $0.utf8.lexicographicallyPrecedes($1.utf8)
            }

        for path in allPaths {
            let key = pathKey(path)
            if let existingId = idByPath[key] {
                let leafName = path.split(separator: "/").last.map(String.init) ?? path
                if let index = indexByID[existingId],
                   records[index].missingOnDisk || records[index].leafName != leafName {
                    _ = try ProjectRecord
                        .filter(Column("id") == existingId)
                        .updateAll(
                            db,
                            Column("leafName").set(to: leafName),
                            Column("leafNameKey").set(to: DahliaProjectName.siblingKey(leafName)),
                            Column("missingOnDisk").set(to: false),
                            Column("revision").set(to: Column("revision") + 1)
                        )
                    records[index].leafName = leafName
                    records[index].missingOnDisk = false
                }
                continue
            }

            let components = path.split(separator: "/")
            guard let leaf = components.last else { continue }
            let parentPath = components.dropLast().joined(separator: "/")
            let parentId = parentPath.isEmpty ? nil : idByPath[pathKey(parentPath)]
            guard parentPath.isEmpty || parentId != nil else { continue }

            let record = ProjectRecord(
                id: .v7(),
                vaultId: vaultId,
                parentProjectId: parentId,
                leafName: String(leaf),
                createdAt: .now,
                projectType: parentId == nil ? .undefined : nil,
                resolvedPath: path
            )
            try record.insert(db)
            records.append(record)
            indexByID[record.id] = records.index(before: records.endIndex)
            idByPath[key] = record.id
        }
    }

    static func setMissing(ids: Set<UUID>, missing: Bool, in db: Database) throws {
        guard !ids.isEmpty else { return }
        _ = try ProjectRecord
            .filter(ids.contains(Column("id")))
            .updateAll(
                db,
                Column("missingOnDisk").set(to: missing),
                Column("revision").set(to: Column("revision") + 1)
            )
    }

    static func incrementRevisions(_ ids: Set<UUID>, in db: Database) throws {
        guard !ids.isEmpty else { return }
        _ = try ProjectRecord
            .filter(ids.contains(Column("id")))
            .updateAll(db, Column("revision").set(to: Column("revision") + 1))
    }

    static func setMissingByPrefix(
        _ prefix: String,
        missing: Bool,
        vaultId: UUID,
        in db: Database
    ) throws {
        let ids = try Set(
            fetchResolvedAll(vaultId: vaultId, in: db)
                .filter { belongsToHierarchy($0.name, prefix: prefix) }
                .map(\.id)
        )
        try setMissing(ids: ids, missing: missing, in: db)
    }

    static func allIntermediatePaths(for path: String) -> [String] {
        let components = path.split(separator: "/")
        return components.indices.map { index in
            components[...index].joined(separator: "/")
        }
    }

    static func belongsToHierarchy(_ path: String, prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    static func pathKey(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { DahliaProjectName.siblingKey(String($0)) }
            .joined(separator: "/")
    }
}
