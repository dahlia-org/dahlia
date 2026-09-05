import DahliaRuntimeSupport
import Foundation
import GRDB

/// A stable Project entity. The canonical hierarchy is parentProjectId + name.
struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "projects"

    var id: UUID
    var vaultId: UUID
    var parentProjectId: UUID?
    var name: String {
        didSet {
            nameKey = DahliaProjectName.siblingKey(name)
        }
    }

    var nameKey: String
    var createdAt: Date
    var description = ""
    var projectType: ProjectType?
    var revision = 1

    /// Populated by hierarchy-aware repository reads. It is never persisted.
    var resolvedPath: String?

    var path: String {
        resolvedPath ?? name
    }

    enum CodingKeys: String, CodingKey {
        case id
        case vaultId
        case parentProjectId
        case name
        case nameKey
        case createdAt
        case description
        case projectType
        case revision
    }

    init(
        id: UUID,
        vaultId: UUID,
        parentProjectId: UUID?,
        name: String,
        createdAt: Date,
        description: String = "",
        projectType: ProjectType?,
        revision: Int = 1,
        resolvedPath: String? = nil
    ) {
        self.id = id
        self.vaultId = vaultId
        self.parentProjectId = parentProjectId
        self.name = name
        nameKey = DahliaProjectName.siblingKey(name)
        self.createdAt = createdAt
        self.description = description
        self.projectType = projectType
        self.revision = revision
        self.resolvedPath = resolvedPath
    }

    /// Compatibility initializer for call sites that construct a root or an in-memory path fixture.
    init(
        id: UUID,
        vaultId: UUID,
        path: String,
        createdAt: Date,
        description: String = ""
    ) {
        self.init(
            id: id,
            vaultId: vaultId,
            parentProjectId: nil,
            name: path.split(separator: "/").last.map(String.init) ?? path,
            createdAt: createdAt,
            description: description,
            projectType: .undefined,
            resolvedPath: path
        )
    }

    static func fetchResolved(id: UUID, in db: Database) throws -> Self? {
        guard let record = try fetchOne(db, key: id) else { return nil }
        return try fetchResolvedAll(vaultId: record.vaultId, in: db).first { $0.id == id }
    }

    static func fetchResolvedAll(vaultId: UUID, in db: Database) throws -> [Self] {
        var records = try Self
            .filter(Column("vaultId") == vaultId)
            .fetchAll(db)
        let paths = resolvedPaths(records)
        for index in records.indices {
            records[index].resolvedPath = paths[records[index].id]
        }
        return records.sorted {
            if $0.path == $1.path { return $0.id.uuidString < $1.id.uuidString }
            return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
    }

    static func resolvedPaths(_ records: [Self]) -> [UUID: String] {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var paths: [UUID: String] = [:]

        func resolve(_ record: Self, visiting: Set<UUID>) -> String {
            if let path = paths[record.id] { return path }
            guard let parentProjectId = record.parentProjectId,
                  let parent = recordsByID[parentProjectId],
                  !visiting.contains(parentProjectId)
            else {
                paths[record.id] = record.name
                return record.name
            }
            let parentPath = resolve(parent, visiting: visiting.union([record.id]))
            let path = "\(parentPath)/\(record.name)"
            paths[record.id] = path
            return path
        }

        for record in records {
            _ = resolve(record, visiting: [])
        }
        return paths
    }

    static func hierarchy(projectId: UUID, vaultId: UUID, in db: Database) throws -> [Self] {
        let records = try fetchResolvedAll(vaultId: vaultId, in: db)
        return hierarchy(projectId: projectId, records: records)
    }

    static func hierarchy(projectId: UUID, records: [Self]) -> [Self] {
        let childrenByParent = Dictionary(grouping: records, by: \.parentProjectId)
        var result: [Self] = []

        func append(_ project: Self) {
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
        records: [Self]
    ) -> (type: ProjectType, ownerProjectId: UUID)? {
        effectiveTypes(records)[projectId]
    }

    static func effectiveTypes(
        _ records: [Self]
    ) -> [UUID: (type: ProjectType, ownerProjectId: UUID)] {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var result: [UUID: (type: ProjectType, ownerProjectId: UUID)] = [:]

        func resolve(
            _ project: Self,
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

    static func incrementRevisions(_ ids: Set<UUID>, in db: Database) throws {
        guard !ids.isEmpty else { return }
        _ = try filter(ids.contains(Column("id")))
            .updateAll(db, Column("revision").set(to: Column("revision") + 1))
    }

    static func applyCanonical(
        id: UUID,
        vaultId: UUID,
        parentProjectId: UUID?,
        name: String,
        createdAt: Date,
        description: String,
        projectType: ProjectType?,
        in db: Database
    ) throws {
        guard var project = try fetchOne(db, key: id) else {
            try Self(
                id: id,
                vaultId: vaultId,
                parentProjectId: parentProjectId,
                name: name,
                createdAt: createdAt,
                description: description,
                projectType: projectType
            ).insert(db)
            return
        }
        guard project.vaultId == vaultId else {
            throw ProjectWorkspaceError.projectNotFound
        }

        let hierarchyChanged = project.parentProjectId != parentProjectId
            || project.name != name
            || project.projectType != projectType
        guard hierarchyChanged
            || project.createdAt != createdAt
            || project.description != description else { return }
        let descendantIDs = try Set(hierarchy(projectId: id, vaultId: vaultId, in: db).dropFirst().map(\.id))
        project.parentProjectId = parentProjectId
        project.name = name
        project.createdAt = createdAt
        project.description = description
        project.projectType = projectType
        project.revision += 1
        try project.update(db)
        try incrementRevisions(hierarchyChanged ? descendantIDs : [], in: db)
    }

}
