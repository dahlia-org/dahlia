import DahliaRuntimeSupport
import Darwin
import Foundation
import GRDB

public extension MeetingAccessStore {
    func queryProjects(_ query: ProjectQuery = ProjectQuery()) throws -> ProjectQueryResult {
        try database.read { db in
            let vault = try workspaceVault(in: db)
            let projects = try projectMetadata(in: db)
            let normalizedQuery = query.query?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProjectQueryResult(
                vault: vault.scoped,
                projects: projects.filter { project in
                    if let projectID = query.projectID, project.projectID != projectID { return false }
                    if let type = query.type, project.effectiveType != type { return false }
                    guard let normalizedQuery, !normalizedQuery.isEmpty else { return true }
                    return project.displayName.localizedCaseInsensitiveContains(normalizedQuery)
                        || project.path.localizedCaseInsensitiveContains(normalizedQuery)
                        || project.description.localizedCaseInsensitiveContains(normalizedQuery)
                }
            )
        }
    }

    func createProject(
        leafName: String,
        parentProjectID: UUID?,
        projectType: ProjectWorkspaceType?,
        description: String = ""
    ) throws -> ProjectMutationResult {
        try requireWriteAccess()
        let leafName = try validatedLeafName(leafName)
        let vault = try database.read(workspaceVault(in:))
        var committed = false

        do {
            let result = try withVaultMutationLock(vaultURL: vault.url) {
                let plan = try database.read { db -> (parentPath: String?, parentID: UUID?) in
                    let rows = try projectRows(in: db)
                    if let parentProjectID {
                        guard let parent = rows.first(where: { $0.id == parentProjectID }) else {
                            throw MeetingAccessError.projectNotFound
                        }
                        guard !parent.missingOnDisk else { throw MeetingAccessError.projectDirectoryMissing }
                        guard projectType == nil else { throw MeetingAccessError.projectTypeOwnedByRoot }
                        try validateSiblingName(
                            leafName,
                            parentProjectID: parent.id,
                            excluding: nil,
                            rows: rows
                        )
                        return (resolvedProjectPaths(rows)[parent.id], parent.id)
                    }
                    try validateSiblingName(leafName, parentProjectID: nil, excluding: nil, rows: rows)
                    return (nil, nil)
                }

                let parentURL = plan.parentPath.map {
                    vault.url.appending(path: $0, directoryHint: .isDirectory)
                } ?? vault.url
                try validateExistingDirectoryInsideVault(parentURL, vaultURL: vault.url)
                let destinationURL = parentURL.appending(path: leafName, directoryHint: .isDirectory)
                try validateNoSiblingCollision(named: leafName, in: parentURL)
                try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)

                let id = workspaceUUIDv7()
                do {
                    try database.write { db in
                        try db.execute(
                            sql: """
                            INSERT INTO projects (
                                id, vaultId, parentProjectId, leafName, leafNameKey, createdAt, missingOnDisk,
                                description, legacyContextMigrated, projectType, revision
                            )
                            VALUES (?, ?, ?, ?, ?, ?, 0, ?, 1, ?, 1)
                            """,
                            arguments: [
                                id,
                                vaultID,
                                plan.parentID,
                                leafName,
                                DahliaProjectName.siblingKey(leafName),
                                Date.now,
                                description,
                                plan.parentID == nil ? (projectType ?? .undefined).rawValue : nil,
                            ]
                        )
                    }
                    committed = true
                } catch {
                    do {
                        try removeEmptyDirectory(destinationURL)
                    } catch {
                        throw MeetingAccessError.workspaceRollbackFailed
                    }
                    throw error
                }

                let project = try requiredProjectMetadata(id: id)
                return ProjectMutationResult(
                    project: project,
                    changed: true,
                    affectedProjectIDs: [id],
                    effectiveTypeChangedProjectIDs: []
                )
            }
            DahliaWorkspaceChangeNotification.post(vaultID: vaultID)
            return result
        } catch {
            if committed {
                DahliaWorkspaceChangeNotification.post(vaultID: vaultID)
            }
            throw error
        }
    }

    func updateProject(id: UUID, update: ProjectUpdate) throws -> ProjectMutationResult {
        try requireWriteAccess()
        let vault = try database.read(workspaceVault(in:))
        var committed = false

        do {
            let result = try withVaultMutationLock(vaultURL: vault.url) {
                let beforeRows = try database.read(projectRows(in:))
                let plan = try makeProjectUpdatePlan(id: id, update: update, rows: beforeRows)
                guard plan.changed else {
                    return try ProjectMutationResult(
                        project: requiredProjectMetadata(id: id),
                        changed: false,
                        affectedProjectIDs: [],
                        effectiveTypeChangedProjectIDs: []
                    )
                }
                if plan.pathChanged, plan.projectWasMissingOnDisk {
                    throw MeetingAccessError.projectDirectoryMissing
                }

                let oldURL = vault.url.appending(path: plan.oldPath, directoryHint: .isDirectory)
                let newURL = vault.url.appending(path: plan.newPath, directoryHint: .isDirectory)
                if plan.pathChanged {
                    try validateExistingDirectoryInsideVault(oldURL, vaultURL: vault.url)
                    let destinationParent = newURL.deletingLastPathComponent()
                    try validateExistingDirectoryInsideVault(destinationParent, vaultURL: vault.url)
                    try validateNoSiblingCollision(
                        named: newURL.lastPathComponent,
                        in: destinationParent,
                        excluding: oldURL
                    )
                    try moveItemSupportingCaseOnlyRename(from: oldURL, to: newURL)
                }

                do {
                    try commitProjectUpdate(id: id, expectedRevision: update.expectedRevision, plan: plan)
                } catch {
                    if plan.pathChanged {
                        do {
                            try moveItemSupportingCaseOnlyRename(from: newURL, to: oldURL)
                        } catch {
                            throw MeetingAccessError.workspaceRollbackFailed
                        }
                    }
                    throw error
                }

                committed = true
                let afterRows = try database.read(projectRows(in:))
                let afterTypes = effectiveProjectTypes(afterRows)
                let effectiveTypeChanged = plan.hierarchyIDs.filter {
                    plan.effectiveTypesBefore[$0]?.type != afterTypes[$0]?.type
                }
                return try ProjectMutationResult(
                    project: requiredProjectMetadata(id: id),
                    changed: true,
                    affectedProjectIDs: (plan.pathChanged || plan.typeChanged ? plan.hierarchyIDs : [id])
                        .sorted(by: uuidSort),
                    effectiveTypeChangedProjectIDs: effectiveTypeChanged.sorted(by: uuidSort)
                )
            }
            if result.changed { DahliaWorkspaceChangeNotification.post(vaultID: vaultID) }
            return result
        } catch {
            if committed {
                DahliaWorkspaceChangeNotification.post(vaultID: vaultID)
            }
            throw error
        }
    }

    func setMeetingProjectMemberships(
        _ expectations: [MeetingProjectMembershipExpectation],
        projectID: UUID?
    ) throws -> MeetingProjectMembershipResult {
        try requireWriteAccess()
        guard !expectations.isEmpty else {
            return MeetingProjectMembershipResult(changed: false, changedMeetingIDs: [], projectID: projectID)
        }
        guard Set(expectations.map(\.meetingID)).count == expectations.count else {
            throw MeetingAccessError.meetingMembershipConflict
        }
        let vault = try database.read(workspaceVault(in:))

        let result = try withVaultMutationLock(vaultURL: vault.url) {
            let projectPath = try membershipDestinationProjectPath(projectID: projectID)
            let changedIDs = try database.read { db in
                try changedMeetingIDs(
                    expectations: expectations,
                    destinationProjectID: projectID,
                    in: db
                )
            }
            guard !changedIDs.isEmpty else {
                return MeetingProjectMembershipResult(changed: false, changedMeetingIDs: [], projectID: projectID)
            }

            let destinationDirectory = projectPath.map {
                vault.url.appending(path: $0, directoryHint: .isDirectory)
            } ?? vault.url
            try validateExistingDirectoryInsideVault(destinationDirectory, vaultURL: vault.url)
            let summaryPlan = try database.read { db in
                try makeSummaryMovePlan(
                    meetingIDs: Set(changedIDs),
                    destinationDirectory: destinationDirectory,
                    vaultURL: vault.url,
                    in: db
                )
            }
            try performSummaryFileMoves(summaryPlan.moves) {
                try commitMeetingMemberships(
                    expectations: expectations,
                    projectID: projectID,
                    meetingIDs: changedIDs,
                    summaryUpdates: summaryPlan.updates
                )
            }
            return MeetingProjectMembershipResult(
                changed: true,
                changedMeetingIDs: changedIDs.sorted(by: uuidSort),
                projectID: projectID
            )
        }
        if result.changed {
            DahliaWorkspaceChangeNotification.post(vaultID: vaultID)
        }
        return result
    }
}

private extension MeetingAccessStore {
    struct WorkspaceVault {
        let id: UUID
        let name: String
        let path: String

        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
        var scoped: ScopedVault { ScopedVault(id: id, name: name) }
    }

    struct WorkspaceProjectRow {
        let id: UUID
        let parentProjectID: UUID?
        let leafName: String
        let missingOnDisk: Bool
        let description: String
        let projectType: ProjectWorkspaceType?
        let revision: Int
    }

    struct EffectiveProjectType {
        let type: ProjectWorkspaceType
        let ownerProjectID: UUID
    }

    struct ProjectUpdatePlan {
        let parentProjectID: UUID?
        let leafName: String
        let description: String
        let explicitType: ProjectWorkspaceType?
        let oldPath: String
        let newPath: String
        let projectWasMissingOnDisk: Bool
        let previousExplicitType: ProjectWorkspaceType?
        let hierarchyIDs: Set<UUID>
        let effectiveTypesBefore: [UUID: EffectiveProjectType]

        var pathChanged: Bool { oldPath != newPath }
        var typeChanged: Bool { previousExplicitType != explicitType }
        let descriptionChanged: Bool

        var changed: Bool {
            pathChanged || typeChanged || descriptionChanged
        }
    }

    struct SummaryFileMove {
        let source: URL
        let destination: URL
    }

    struct SummaryExportUpdate {
        let meetingID: UUID
        let relativePath: String?
    }

    struct SummaryMovePlan {
        let moves: [SummaryFileMove]
        let updates: [SummaryExportUpdate]
    }

    func requireWriteAccess() throws {
        guard allowsWrites else { throw MeetingAccessError.writeAccessRequired }
    }

    func withVaultMutationLock<T>(vaultURL: URL, operation: () throws -> T) throws -> T {
        do {
            return try DahliaVaultMutationLock.withLock(
                vaultURL: vaultURL,
                vaultID: vaultID,
                operation: operation
            )
        } catch is DahliaVaultMutationLockError {
            throw MeetingAccessError.workspaceBusy
        }
    }

    func workspaceVault(in db: Database) throws -> WorkspaceVault {
        let columns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('projects')"))
        guard columns.isSuperset(of: ["parentProjectId", "leafName", "leafNameKey", "projectType", "revision"]) else {
            throw MeetingAccessError.databaseUpgradeRequired
        }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, name, path FROM vaults WHERE id = ?",
            arguments: [vaultID]
        ) else {
            throw MeetingAccessError.vaultNotFound
        }
        return WorkspaceVault(id: row["id"], name: row["name"], path: row["path"])
    }

    func projectRows(in db: Database) throws -> [WorkspaceProjectRow] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT id, parentProjectId, leafName, missingOnDisk, description, projectType, revision
            FROM projects
            WHERE vaultId = ?
            """,
            arguments: [vaultID]
        ).map { row in
            let rawType: String? = row["projectType"]
            return WorkspaceProjectRow(
                id: row["id"],
                parentProjectID: row["parentProjectId"],
                leafName: row["leafName"],
                missingOnDisk: row["missingOnDisk"],
                description: row["description"],
                projectType: rawType.flatMap(ProjectWorkspaceType.init(rawValue:)),
                revision: row["revision"]
            )
        }
    }

    func resolvedProjectPaths(_ rows: [WorkspaceProjectRow]) -> [UUID: String] {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var result: [UUID: String] = [:]

        func path(for row: WorkspaceProjectRow, visiting: Set<UUID>) -> String {
            if let path = result[row.id] { return path }
            guard let parentID = row.parentProjectID,
                  let parent = byID[parentID],
                  !visiting.contains(parentID) else {
                result[row.id] = row.leafName
                return row.leafName
            }
            let value = "\(path(for: parent, visiting: visiting.union([row.id])))/\(row.leafName)"
            result[row.id] = value
            return value
        }
        for row in rows {
            _ = path(for: row, visiting: [])
        }
        return result
    }

    func effectiveProjectTypes(
        _ rows: [WorkspaceProjectRow]
    ) -> [UUID: EffectiveProjectType] {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var result: [UUID: EffectiveProjectType] = [:]

        func resolve(_ row: WorkspaceProjectRow, visiting: Set<UUID>) -> EffectiveProjectType? {
            if let effective = result[row.id] { return effective }
            guard !visiting.contains(row.id) else { return nil }
            let effective: EffectiveProjectType? = if let parentID = row.parentProjectID, let parent = byID[parentID] {
                resolve(parent, visiting: visiting.union([row.id]))
            } else {
                EffectiveProjectType(
                    type: row.projectType ?? .undefined,
                    ownerProjectID: row.id
                )
            }
            result[row.id] = effective
            return effective
        }

        for row in rows {
            _ = resolve(row, visiting: [])
        }
        return result
    }

    func makeProjectUpdatePlan(
        id: UUID,
        update: ProjectUpdate,
        rows: [WorkspaceProjectRow]
    ) throws -> ProjectUpdatePlan {
        guard let project = rows.first(where: { $0.id == id }) else {
            throw MeetingAccessError.projectNotFound
        }
        guard project.revision == update.expectedRevision else {
            throw MeetingAccessError.projectConflict(
                "expected revision \(update.expectedRevision), current revision \(project.revision)"
            )
        }

        let paths = resolvedProjectPaths(rows)
        let effectiveTypes = effectiveProjectTypes(rows)
        let hierarchyIDs = projectHierarchyIDs(rootID: id, rows: rows)
        let leafName = try update.leafName.map(validatedLeafName) ?? project.leafName
        let parentProjectID: UUID? = switch update.parent {
        case .unchanged: project.parentProjectID
        case .vaultRoot: nil
        case let .project(parentID): parentID
        }

        guard parentProjectID != id,
              parentProjectID.map({ !hierarchyIDs.contains($0) }) ?? true else {
            throw MeetingAccessError.projectConflict("a project cannot be parented to itself or its descendant")
        }
        let parent = parentProjectID.flatMap { parentID in rows.first(where: { $0.id == parentID }) }
        if parentProjectID != nil, parent == nil {
            throw MeetingAccessError.projectNotFound
        }
        if parent?.missingOnDisk == true {
            throw MeetingAccessError.projectDirectoryMissing
        }
        if update.projectType != nil,
           project.parentProjectID != nil || parentProjectID != nil {
            throw MeetingAccessError.projectTypeOwnedByRoot
        }

        let oldPath = paths[id] ?? project.leafName
        let parentPath = parentProjectID.flatMap { paths[$0] }
        let newPath = parentPath.map { "\($0)/\(leafName)" } ?? leafName
        try validateSiblingName(
            leafName,
            parentProjectID: parentProjectID,
            excluding: id,
            rows: rows
        )
        let explicitType = resolvedExplicitType(
            update: update,
            project: project,
            parentProjectID: parentProjectID,
            effectiveType: effectiveTypes[id]?.type ?? .undefined
        )
        let description = update.description ?? project.description
        return ProjectUpdatePlan(
            parentProjectID: parentProjectID,
            leafName: leafName,
            description: description,
            explicitType: explicitType,
            oldPath: oldPath,
            newPath: newPath,
            projectWasMissingOnDisk: project.missingOnDisk,
            previousExplicitType: project.projectType,
            hierarchyIDs: hierarchyIDs,
            effectiveTypesBefore: effectiveTypes,
            descriptionChanged: project.description != description
        )
    }

    func resolvedExplicitType(
        update: ProjectUpdate,
        project: WorkspaceProjectRow,
        parentProjectID: UUID?,
        effectiveType: ProjectWorkspaceType
    ) -> ProjectWorkspaceType? {
        guard parentProjectID == nil else { return nil }
        if let projectType = update.projectType {
            return projectType
        }
        if project.parentProjectID == nil {
            return project.projectType ?? .undefined
        }
        return effectiveType
    }

    func commitProjectUpdate(
        id: UUID,
        expectedRevision: Int,
        plan: ProjectUpdatePlan
    ) throws {
        try database.write { db in
            guard try Int.fetchOne(
                db,
                sql: "SELECT revision FROM projects WHERE id = ? AND vaultId = ?",
                arguments: [id, vaultID]
            ) == expectedRevision else {
                throw MeetingAccessError.projectConflict("the project changed before the update was committed")
            }
            try db.execute(
                sql: """
                UPDATE projects
                SET parentProjectId = ?, leafName = ?, leafNameKey = ?,
                    description = ?, projectType = ?, revision = revision + 1
                WHERE id = ? AND vaultId = ?
                """,
                arguments: [
                    plan.parentProjectID,
                    plan.leafName,
                    DahliaProjectName.siblingKey(plan.leafName),
                    plan.description,
                    plan.explicitType?.rawValue,
                    id,
                    vaultID,
                ]
            )
            if plan.pathChanged || plan.typeChanged {
                let descendants = plan.hierarchyIDs.subtracting([id])
                if !descendants.isEmpty {
                    try incrementProjectRevisions(descendants, in: db)
                }
            }
            if plan.pathChanged {
                try renameSummaryExportPaths(oldPrefix: plan.oldPath, newPrefix: plan.newPath, in: db)
            }
        }
    }

    func projectHierarchyIDs(rootID: UUID, rows: [WorkspaceProjectRow]) -> Set<UUID> {
        let children = Dictionary(grouping: rows, by: \.parentProjectID)
        var result: Set<UUID> = []
        func append(_ id: UUID) {
            guard result.insert(id).inserted else { return }
            for child in children[id, default: []] {
                append(child.id)
            }
        }
        append(rootID)
        return result
    }

    func projectMetadata(in db: Database) throws -> [ProjectMetadata] {
        let rows = try projectRows(in: db)
        let paths = resolvedProjectPaths(rows)
        let effectiveTypes = effectiveProjectTypes(rows)
        let directCounts = try Dictionary(
            uniqueKeysWithValues: Row.fetchAll(
                db,
                sql: """
                SELECT projectId, COUNT(*) AS count
                FROM meetings
                WHERE vaultId = ? AND projectId IS NOT NULL
                GROUP BY projectId
                """,
                arguments: [vaultID]
            ).map { row -> (UUID, Int) in (row["projectId"], row["count"]) }
        )
        let children = Dictionary(grouping: rows, by: \.parentProjectID)
        var descendantCounts: [UUID: Int] = [:]
        func descendantCount(_ id: UUID) -> Int {
            if let count = descendantCounts[id] { return count }
            let count = directCounts[id, default: 0]
                + children[id, default: []].reduce(0) { $0 + descendantCount($1.id) }
            descendantCounts[id] = count
            return count
        }
        return rows.map { row in
            let effective = effectiveTypes[row.id] ?? EffectiveProjectType(
                type: .undefined,
                ownerProjectID: row.id
            )
            return ProjectMetadata(
                projectID: row.id,
                displayName: row.leafName,
                path: paths[row.id] ?? row.leafName,
                parentProjectID: row.parentProjectID,
                rootProjectID: effective.ownerProjectID,
                explicitType: row.projectType,
                effectiveType: effective.type,
                typeOwnerProjectID: effective.ownerProjectID,
                isTypeInherited: row.parentProjectID != nil,
                directMeetingCount: directCounts[row.id, default: 0],
                descendantMeetingCount: descendantCount(row.id),
                directoryMissing: row.missingOnDisk,
                description: row.description,
                revision: row.revision
            )
        }.sorted {
            let order = $0.path.localizedStandardCompare($1.path)
            return order == .orderedSame ? uuidSort($0.projectID, $1.projectID) : order == .orderedAscending
        }
    }

    func requiredProjectMetadata(id: UUID) throws -> ProjectMetadata {
        try database.read { db in
            guard let project = try projectMetadata(in: db).first(where: { $0.projectID == id }) else {
                throw MeetingAccessError.projectNotFound
            }
            return project
        }
    }

    func validatedLeafName(_ value: String) throws -> String {
        guard let value = DahliaProjectName.normalizedLeafName(value) else {
            throw MeetingAccessError.invalidProjectName
        }
        return value
    }

    func validateSiblingName(
        _ leafName: String,
        parentProjectID: UUID?,
        excluding excludedID: UUID?,
        rows: [WorkspaceProjectRow]
    ) throws {
        guard !rows.contains(where: {
            $0.id != excludedID
                && $0.parentProjectID == parentProjectID
                && DahliaProjectName.siblingKey($0.leafName) == DahliaProjectName.siblingKey(leafName)
        }) else {
            throw MeetingAccessError.projectFileConflict(leafName)
        }
    }

    func validateNoSiblingCollision(
        named leafName: String,
        in parentDirectory: URL,
        excluding excludedURL: URL? = nil
    ) throws {
        let excludedURL = excludedURL?.standardizedFileURL
        let entries = try FileManager.default.contentsOfDirectory(
            at: parentDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard !entries.contains(where: {
            $0.standardizedFileURL != excludedURL
                && DahliaProjectName.siblingKey($0.lastPathComponent) == DahliaProjectName.siblingKey(leafName)
        }) else {
            throw MeetingAccessError.projectFileConflict(
                parentDirectory.appending(path: leafName).path
            )
        }
    }

    func removeEmptyDirectory(_ url: URL) throws {
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.rmdir(path)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func validateExistingDirectoryInsideVault(_ directory: URL, vaultURL: URL) throws {
        try validatePathContainsNoSymlink(directory, vaultURL: vaultURL)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw MeetingAccessError.projectDirectoryMissing }
        let rootPath = vaultURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath == rootPath || candidatePath.hasPrefix(prefix) else {
            throw MeetingAccessError.projectFileConflict(directory.path)
        }
    }

    func moveItemSupportingCaseOnlyRename(from source: URL, to destination: URL) throws {
        if DahliaProjectName.siblingKey(source.lastPathComponent)
            == DahliaProjectName.siblingKey(destination.lastPathComponent) {
            let temporary = source.deletingLastPathComponent()
                .appending(path: ".dahlia-rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: source, to: temporary)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch let operationError {
                do {
                    try FileManager.default.moveItem(at: temporary, to: source)
                } catch {
                    throw MeetingAccessError.workspaceRollbackFailed
                }
                throw operationError
            }
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    func incrementProjectRevisions(_ ids: Set<UUID>, in db: Database) throws {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: "UPDATE projects SET revision = revision + 1 WHERE id IN (\(placeholders))",
            arguments: StatementArguments(ids)
        )
    }

    func renameSummaryExportPaths(oldPrefix: String, newPrefix: String, in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT summary_exports.meetingId, summary_exports.url
            FROM summary_exports
            JOIN meetings ON meetings.id = summary_exports.meetingId
            WHERE summary_exports.type = 'vault' AND meetings.vaultId = ?
            """,
            arguments: [vaultID]
        )
        for row in rows {
            let url: String = row["url"]
            guard let path = vaultRelativeSummaryPath(url),
                  path == oldPrefix || path.hasPrefix(oldPrefix + "/") else { continue }
            let newPath = newPrefix + path.dropFirst(oldPrefix.count)
            let meetingID: UUID = row["meetingId"]
            try db.execute(
                sql: """
                UPDATE summary_exports SET url = ?, updatedAt = ?
                WHERE meetingId = ? AND type = 'vault'
                """,
                arguments: [vaultSummaryURL(String(newPath)), Date.now, meetingID]
            )
        }
    }

    func membershipDestinationProjectPath(projectID: UUID?) throws -> String? {
        try database.read { db in
            let rows = try projectRows(in: db)
            guard let projectID else { return nil }
            guard let project = rows.first(where: { $0.id == projectID }) else {
                throw MeetingAccessError.projectNotFound
            }
            guard !project.missingOnDisk else {
                throw MeetingAccessError.projectDirectoryMissing
            }
            return resolvedProjectPaths(rows)[projectID]
        }
    }

    func changedMeetingIDs(
        expectations: [MeetingProjectMembershipExpectation],
        destinationProjectID: UUID?,
        in db: Database
    ) throws -> [UUID] {
        let meetingIDs = expectations.map(\.meetingID)
        let placeholders = meetingIDs.map { _ in "?" }.joined(separator: ",")
        var arguments: StatementArguments = [vaultID]
        arguments += StatementArguments(meetingIDs)
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, projectId
            FROM meetings
            WHERE vaultId = ? AND id IN (\(placeholders))
            """,
            arguments: arguments
        )
        let currentProjects = Dictionary(uniqueKeysWithValues: rows.map { row -> (UUID, UUID?) in
            (row["id"], row["projectId"])
        })
        guard currentProjects.count == expectations.count else {
            throw MeetingAccessError.meetingMembershipConflict
        }

        var changedIDs: [UUID] = []
        for expectation in expectations {
            guard let currentValue = currentProjects[expectation.meetingID] else {
                throw MeetingAccessError.meetingMembershipConflict
            }
            guard currentValue == expectation.expectedProjectID else {
                throw MeetingAccessError.meetingMembershipConflict
            }
            if currentValue != destinationProjectID {
                changedIDs.append(expectation.meetingID)
            }
        }
        return changedIDs
    }

    func commitMeetingMemberships(
        expectations: [MeetingProjectMembershipExpectation],
        projectID: UUID?,
        meetingIDs: [UUID],
        summaryUpdates: [SummaryExportUpdate]
    ) throws {
        try database.write { db in
            _ = try changedMeetingIDs(
                expectations: expectations,
                destinationProjectID: projectID,
                in: db
            )
            for meetingID in meetingIDs {
                try db.execute(
                    sql: "UPDATE meetings SET projectId = ?, updatedAt = ? WHERE id = ? AND vaultId = ?",
                    arguments: [projectID, Date.now, meetingID, vaultID]
                )
            }
            for update in summaryUpdates {
                try applySummaryExportUpdate(update, in: db)
            }
        }
    }

    func applySummaryExportUpdate(_ update: SummaryExportUpdate, in db: Database) throws {
        if let relativePath = update.relativePath {
            try db.execute(
                sql: """
                UPDATE summary_exports
                SET url = ?, updatedAt = ?
                WHERE meetingId = ? AND type = 'vault'
                """,
                arguments: [vaultSummaryURL(relativePath), Date.now, update.meetingID]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM summary_exports WHERE meetingId = ? AND type = 'vault'",
                arguments: [update.meetingID]
            )
        }
    }

    func performSummaryFileMoves(
        _ moves: [SummaryFileMove],
        operation: () throws -> Void
    ) throws {
        var completedMoves: [SummaryFileMove] = []
        do {
            for move in moves {
                try FileManager.default.moveItem(at: move.source, to: move.destination)
                completedMoves.append(move)
            }
            try operation()
        } catch {
            var rollbackFailed = false
            for move in completedMoves.reversed() {
                do {
                    try FileManager.default.moveItem(at: move.destination, to: move.source)
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed {
                throw MeetingAccessError.workspaceRollbackFailed
            }
            throw error
        }
    }

    func makeSummaryMovePlan(
        meetingIDs: Set<UUID>,
        destinationDirectory: URL,
        vaultURL: URL,
        in db: Database
    ) throws -> SummaryMovePlan {
        guard !meetingIDs.isEmpty else { return SummaryMovePlan(moves: [], updates: []) }
        let placeholders = meetingIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT meetingId, url
            FROM summary_exports
            WHERE type = 'vault' AND meetingId IN (\(placeholders))
            """,
            arguments: StatementArguments(meetingIDs)
        )
        var externalArguments: StatementArguments = [vaultID]
        externalArguments += StatementArguments(meetingIDs)
        let externalURLs = try String.fetchAll(
            db,
            sql: """
            SELECT summary_exports.url
            FROM summary_exports
            JOIN meetings ON meetings.id = summary_exports.meetingId
            WHERE summary_exports.type = 'vault'
              AND meetings.vaultId = ?
              AND summary_exports.meetingId NOT IN (\(placeholders))
            """,
            arguments: externalArguments
        )
        let externallyReferencedSources = Set(externalURLs.compactMap { storedURL -> DahliaWorkspaceFileIdentity? in
            guard let relativePath = vaultRelativeSummaryPath(storedURL) else { return nil }
            let source = vaultURL.appending(path: relativePath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: source.path) else { return nil }
            return DahliaWorkspaceFileIdentity.resolve(source)
        })
        let existingDestinationKeys = try normalizedSiblingKeys(in: destinationDirectory)
        var moves: [SummaryFileMove] = []
        var updates: [SummaryExportUpdate] = []
        var destinations: Set<String> = []
        var destinationBySource: [DahliaWorkspaceFileIdentity: URL] = [:]
        for row in rows {
            let meetingID: UUID = row["meetingId"]
            let storedURL: String = row["url"]
            guard let relativePath = vaultRelativeSummaryPath(storedURL) else {
                updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: nil))
                continue
            }
            let source = vaultURL.appending(path: relativePath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: source.path) else {
                updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: nil))
                continue
            }
            guard isInsideVault(source, vaultURL: vaultURL) else {
                throw MeetingAccessError.projectFileConflict(source.path)
            }
            let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard source.pathExtension.lowercased() == "md",
                  sourceValues.isRegularFile == true,
                  sourceValues.isSymbolicLink != true else {
                updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: nil))
                continue
            }
            try validatePathContainsNoSymlink(source, vaultURL: vaultURL)
            let destination = destinationDirectory.appending(path: source.lastPathComponent).standardizedFileURL
            let newRelativePath = String(destination.path.dropFirst(vaultURL.standardizedFileURL.path.count + 1))
            updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: newRelativePath))
            guard source != destination else { continue }

            let sourceIdentity = DahliaWorkspaceFileIdentity.resolve(source)
            guard !externallyReferencedSources.contains(sourceIdentity) else {
                throw MeetingAccessError.projectFileConflict(source.path)
            }
            if let plannedDestination = destinationBySource[sourceIdentity] {
                guard plannedDestination == destination else {
                    throw MeetingAccessError.projectFileConflict(source.path)
                }
                continue
            }
            let key = DahliaProjectName.siblingKey(destination.path)
            guard destinations.insert(key).inserted,
                  !existingDestinationKeys.contains(DahliaProjectName.siblingKey(destination.lastPathComponent)) else {
                throw MeetingAccessError.projectFileConflict(destination.path)
            }
            destinationBySource[sourceIdentity] = destination
            moves.append(SummaryFileMove(source: source, destination: destination))
        }
        return SummaryMovePlan(moves: moves, updates: updates)
    }

    func normalizedSiblingKeys(in directory: URL) throws -> Set<String> {
        try Set(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).map { DahliaProjectName.siblingKey($0.lastPathComponent) }
        )
    }

    func vaultRelativeSummaryPath(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "vault",
              components.host?.isEmpty != false else { return nil }
        let path = String(components.path.drop(while: { $0 == "/" }))
        return path.isEmpty ? nil : path
    }

    func vaultSummaryURL(_ relativePath: String) -> String {
        var components = URLComponents()
        components.scheme = "vault"
        components.host = ""
        components.path = "/" + relativePath
        return components.string ?? "vault:///\(relativePath)"
    }

    func isInsideVault(_ value: URL, vaultURL: URL) -> Bool {
        let rootPath = vaultURL.resolvingSymlinksInPath().standardizedFileURL.path
        let valuePath = value.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return valuePath.hasPrefix(prefix)
    }

    func validatePathContainsNoSymlink(_ value: URL, vaultURL: URL) throws {
        let root = vaultURL.standardizedFileURL
        let candidate = value.standardizedFileURL
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.starts(with: rootComponents) else {
            throw MeetingAccessError.projectFileConflict(candidate.path)
        }

        var current = root
        for component in candidateComponents.dropFirst(rootComponents.count) {
            current.append(path: component)
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw MeetingAccessError.projectFileConflict(current.path)
            }
        }
    }

    func uuidSort(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    func workspaceUUIDv7() -> UUID {
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = (
            UInt8(truncatingIfNeeded: milliseconds >> 40),
            UInt8(truncatingIfNeeded: milliseconds >> 32),
            UInt8(truncatingIfNeeded: milliseconds >> 24),
            UInt8(truncatingIfNeeded: milliseconds >> 16),
            UInt8(truncatingIfNeeded: milliseconds >> 8),
            UInt8(truncatingIfNeeded: milliseconds),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)
        )
        withUnsafeMutableBytes(of: &bytes) { buffer in
            for index in 6 ..< 16 {
                buffer[index] = UInt8.random(in: 0 ... 255)
            }
        }
        bytes.6 = (bytes.6 & 0x0F) | 0x70
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
    }
}
