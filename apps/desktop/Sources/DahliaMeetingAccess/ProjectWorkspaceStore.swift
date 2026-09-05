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
                    return project.name.localizedCaseInsensitiveContains(normalizedQuery)
                        || project.path.localizedCaseInsensitiveContains(normalizedQuery)
                        || project.description.localizedCaseInsensitiveContains(normalizedQuery)
                }
            )
        }
    }

    func createProject(
        name: String,
        parentProjectID: UUID?,
        projectType: ProjectWorkspaceType?,
        description: String = ""
    ) throws -> ProjectMutationResult {
        try requireWriteAccess()
        let name = try validatedName(name)
        let vault = try database.read(workspaceVault(in:))
        var committed = false

        do {
            let result = try withVaultMutationLock(vaultURL: vault.url) {
                let parentID = try database.read { db -> UUID? in
                    let rows = try projectRows(in: db)
                    if let parentProjectID {
                        guard let parent = rows.first(where: { $0.id == parentProjectID }) else {
                            throw MeetingAccessError.projectNotFound
                        }
                        guard parent.parentProjectID == nil else {
                            throw MeetingAccessError.projectHierarchyTooDeep
                        }
                        guard projectType == nil else { throw MeetingAccessError.projectTypeOwnedByRoot }
                        try validateSiblingName(
                            name,
                            parentProjectID: parent.id,
                            excluding: nil,
                            rows: rows
                        )
                        return parent.id
                    }
                    try validateSiblingName(name, parentProjectID: nil, excluding: nil, rows: rows)
                    return nil
                }

                let id = workspaceUUIDv7()
                try database.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO projects (
                            id, vaultId, parentProjectId, name, nameKey, createdAt,
                            description, projectType, revision
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                        """,
                        arguments: [
                            id,
                            vaultID,
                            parentID,
                            name,
                            DahliaProjectName.siblingKey(name),
                            Date.now,
                            description,
                            parentID == nil ? (projectType ?? .undefined).rawValue : nil,
                        ]
                    )
                }
                committed = true

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
                let summaryPlan = plan.pathChanged
                    ? try makeProjectSummaryMovePlan(plan: plan, rows: beforeRows, vault: vault)
                    : SummaryMovePlan(moves: [], updates: [])
                try performSummaryFileMoves(summaryPlan.moves, vaultURL: vault.url) {
                    try commitProjectUpdate(
                        id: id,
                        expectedRevision: update.expectedRevision,
                        plan: plan,
                        summaryUpdates: summaryPlan.updates
                    )
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

            let summaryPlan: SummaryMovePlan
            if let vaultURL = vault.url {
                let destinationDirectory = projectPath.map {
                    vaultURL.appending(path: $0, directoryHint: .isDirectory)
                } ?? vaultURL
                summaryPlan = try database.read { db in
                    try makeSummaryMovePlan(
                        meetingIDs: Set(changedIDs),
                        destinationDirectory: destinationDirectory,
                        vaultURL: vaultURL,
                        in: db
                    )
                }
            } else {
                summaryPlan = SummaryMovePlan(moves: [], updates: [])
            }
            try performSummaryFileMoves(summaryPlan.moves, vaultURL: vault.url) {
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
        let path: String?

        var url: URL? { path.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        var scoped: ScopedVault { ScopedVault(id: id, name: name) }
    }

    struct WorkspaceProjectRow {
        let id: UUID
        let parentProjectID: UUID?
        let name: String
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
        let name: String
        let description: String
        let explicitType: ProjectWorkspaceType?
        let oldPath: String
        let newPath: String
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

    func workspaceVault(in db: Database) throws -> WorkspaceVault {
        let columns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('projects')"))
        guard columns.isSuperset(of: ["parentProjectId", "name", "nameKey", "projectType", "revision"]) else {
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
            SELECT id, parentProjectId, name, description, projectType, revision
            FROM projects
            WHERE vaultId = ?
            """,
            arguments: [vaultID]
        ).map { row in
            let rawType: String? = row["projectType"]
            return WorkspaceProjectRow(
                id: row["id"],
                parentProjectID: row["parentProjectId"],
                name: row["name"],
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
                result[row.id] = row.name
                return row.name
            }
            let value = "\(path(for: parent, visiting: visiting.union([row.id])))/\(row.name)"
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
        let name = try update.name.map(validatedName) ?? project.name
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
        if let parent, parent.parentProjectID != nil {
            throw MeetingAccessError.projectHierarchyTooDeep
        }
        if parentProjectID != nil, hierarchyIDs.count > 1 {
            throw MeetingAccessError.projectHierarchyTooDeep
        }
        if update.projectType != nil,
           project.parentProjectID != nil || parentProjectID != nil {
            throw MeetingAccessError.projectTypeOwnedByRoot
        }

        let oldPath = paths[id] ?? project.name
        let parentPath = parentProjectID.flatMap { paths[$0] }
        let newPath = parentPath.map { "\($0)/\(name)" } ?? name
        try validateSiblingName(
            name,
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
            name: name,
            description: description,
            explicitType: explicitType,
            oldPath: oldPath,
            newPath: newPath,
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
        plan: ProjectUpdatePlan,
        summaryUpdates: [SummaryExportUpdate]
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
                SET parentProjectId = ?, name = ?, nameKey = ?,
                    description = ?, projectType = ?, revision = revision + 1
                WHERE id = ? AND vaultId = ?
                """,
                arguments: [
                    plan.parentProjectID,
                    plan.name,
                    DahliaProjectName.siblingKey(plan.name),
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
            for update in summaryUpdates {
                try applySummaryExportUpdate(update, in: db)
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
                name: row.name,
                path: paths[row.id] ?? row.name,
                parentProjectID: row.parentProjectID,
                rootProjectID: effective.ownerProjectID,
                explicitType: row.projectType,
                effectiveType: effective.type,
                typeOwnerProjectID: effective.ownerProjectID,
                isTypeInherited: row.parentProjectID != nil,
                directMeetingCount: directCounts[row.id, default: 0],
                descendantMeetingCount: descendantCount(row.id),
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

    func validatedName(_ value: String) throws -> String {
        guard let value = DahliaProjectName.normalizedName(value) else {
            throw MeetingAccessError.invalidProjectName
        }
        return value
    }

    func validateSiblingName(
        _ name: String,
        parentProjectID: UUID?,
        excluding excludedID: UUID?,
        rows: [WorkspaceProjectRow]
    ) throws {
        guard !rows.contains(where: {
            $0.id != excludedID
                && $0.parentProjectID == parentProjectID
                && DahliaProjectName.siblingKey($0.name) == DahliaProjectName.siblingKey(name)
        }) else {
            throw MeetingAccessError.projectAlreadyExists(name)
        }
    }

    func removeNewEmptyDirectory(_ url: URL) throws {
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.rmdir(path)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func incrementProjectRevisions(_ ids: Set<UUID>, in db: Database) throws {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: "UPDATE projects SET revision = revision + 1 WHERE id IN (\(placeholders))",
            arguments: StatementArguments(ids)
        )
    }

    func membershipDestinationProjectPath(projectID: UUID?) throws -> String? {
        try database.read { db in
            let rows = try projectRows(in: db)
            guard let projectID else { return nil }
            guard rows.contains(where: { $0.id == projectID }) else {
                throw MeetingAccessError.projectNotFound
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
        vaultURL: URL?,
        operation: () throws -> Void
    ) throws {
        guard let vaultURL else { return try operation() }
        let createdDirectories = try createOutputDirectories(for: moves, vaultURL: vaultURL)
        var completedMoves: [SummaryFileMove] = []
        do {
            for move in moves {
                try DahliaVaultFileMover.moveItem(
                    at: move.source,
                    to: move.destination,
                    inside: vaultURL
                )
                completedMoves.append(move)
            }
            try operation()
        } catch let operationError {
            var rollbackFailed = false
            for move in completedMoves.reversed() {
                do {
                    try DahliaVaultFileMover.moveItem(
                        at: move.destination,
                        to: move.source,
                        inside: vaultURL
                    )
                } catch {
                    rollbackFailed = true
                }
            }
            for directory in createdDirectories.reversed() {
                do {
                    try removeNewEmptyDirectory(directory)
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed {
                throw MeetingAccessError.workspaceRollbackFailed
            }
            throw operationError
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
        let externallyReferencedSources = try externalSummaryIdentities(
            excluding: meetingIDs,
            vaultURL: vaultURL,
            in: db
        )
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
            guard isInsideVault(source, vaultURL: vaultURL) else {
                throw MeetingAccessError.projectFileConflict(source.path)
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: nil))
                continue
            }
            let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard source.pathExtension.lowercased() == "md",
                  sourceValues.isRegularFile == true,
                  sourceValues.isSymbolicLink != true else {
                updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: nil))
                continue
            }
            try validatePathContainsNoSymlink(source, vaultURL: vaultURL)
            try validateOutputDirectory(destinationDirectory, vaultURL: vaultURL)
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
                  try !destinationConflicts(destination, sourceIdentity: sourceIdentity) else {
                throw MeetingAccessError.projectFileConflict(destination.path)
            }
            if FileManager.default.fileExists(atPath: destination.path),
               DahliaWorkspaceFileIdentity.resolve(destination) == sourceIdentity {
                destinationBySource[sourceIdentity] = destination
                continue
            }
            destinationBySource[sourceIdentity] = destination
            moves.append(SummaryFileMove(source: source, destination: destination))
        }
        return SummaryMovePlan(moves: moves, updates: updates)
    }

    func makeProjectSummaryMovePlan(
        plan: ProjectUpdatePlan,
        rows: [WorkspaceProjectRow],
        vault: WorkspaceVault
    ) throws -> SummaryMovePlan {
        guard let vaultURL = vault.url else { return SummaryMovePlan(moves: [], updates: []) }
        let paths = resolvedProjectPaths(rows)
        let projectPlaceholders = plan.hierarchyIDs.map { _ in "?" }.joined(separator: ",")
        let meetingIDs = try database.read { db in
            try UUID.fetchSet(
                db,
                sql: """
                SELECT id FROM meetings
                WHERE vaultId = ? AND projectId IN (\(projectPlaceholders))
                """,
                arguments: StatementArguments([vaultID]) + StatementArguments(plan.hierarchyIDs)
            )
        }
        guard !meetingIDs.isEmpty else {
            return SummaryMovePlan(moves: [], updates: [])
        }

        let meetingPlaceholders = meetingIDs.map { _ in "?" }.joined(separator: ",")
        let summaryRows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT summary_exports.meetingId, summary_exports.url, meetings.projectId
                FROM summary_exports
                JOIN meetings ON meetings.id = summary_exports.meetingId
                WHERE summary_exports.type = 'vault'
                  AND summary_exports.meetingId IN (\(meetingPlaceholders))
                """,
                arguments: StatementArguments(meetingIDs)
            )
        }
        let externalIdentities = try database.read { db in
            try externalSummaryIdentities(
                excluding: meetingIDs,
                vaultURL: vaultURL,
                in: db
            )
        }
        var retainedIdentities: Set<DahliaWorkspaceFileIdentity> = []
        for row in summaryRows {
            let projectID: UUID = row["projectId"]
            let storedURL: String = row["url"]
            guard let projectPath = paths[projectID],
                  let storedPath = vaultRelativeSummaryPath(storedURL),
                  !storedPath.hasPrefix(projectPath + "/")
            else {
                continue
            }
            let source = vaultURL.appending(path: storedPath).standardizedFileURL
            guard isInsideVault(source, vaultURL: vaultURL) else {
                throw MeetingAccessError.projectFileConflict(source.path)
            }
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            retainedIdentities.insert(DahliaWorkspaceFileIdentity.resolve(source))
        }
        let protectedIdentities = externalIdentities.union(retainedIdentities)
        var moves: [SummaryFileMove] = []
        var updates: [SummaryExportUpdate] = []
        var destinations: Set<String> = []
        var destinationBySource: [DahliaWorkspaceFileIdentity: URL] = [:]

        for row in summaryRows {
            let meetingID: UUID = row["meetingId"]
            let projectID: UUID = row["projectId"]
            let storedURL: String = row["url"]
            guard let oldProjectPath = paths[projectID] else { continue }
            let newProjectPath = oldProjectPath == plan.oldPath
                ? plan.newPath
                : plan.newPath + oldProjectPath.dropFirst(plan.oldPath.count)
            guard let storedPath = vaultRelativeSummaryPath(storedURL) else {
                updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: nil))
                continue
            }
            let oldDirectoryPrefix = oldProjectPath + "/"
            guard storedPath.hasPrefix(oldDirectoryPrefix) else {
                // Exports retained at a legacy migration path do not move with later Project mutations.
                continue
            }
            let suffix = storedPath.dropFirst(oldDirectoryPrefix.count)
            guard !suffix.isEmpty else {
                updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: nil))
                continue
            }
            let source = vaultURL.appending(path: storedPath).standardizedFileURL
            guard isInsideVault(source, vaultURL: vaultURL) else {
                throw MeetingAccessError.projectFileConflict(source.path)
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: nil))
                continue
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard source.pathExtension.lowercased() == "md",
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                updates.append(SummaryExportUpdate(meetingID: meetingID, relativePath: nil))
                continue
            }
            try validatePathContainsNoSymlink(source, vaultURL: vaultURL)

            let destinationRelativePath = "\(newProjectPath)/\(suffix)"
            let destination = vaultURL.appending(path: destinationRelativePath).standardizedFileURL
            try validateOutputDirectory(destination.deletingLastPathComponent(), vaultURL: vaultURL)
            updates.append(SummaryExportUpdate(
                meetingID: meetingID,
                relativePath: destinationRelativePath
            ))
            guard source != destination else { continue }

            let sourceIdentity = DahliaWorkspaceFileIdentity.resolve(source)
            guard !protectedIdentities.contains(sourceIdentity) else {
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
                  try !destinationConflicts(destination, sourceIdentity: sourceIdentity) else {
                throw MeetingAccessError.projectFileConflict(destination.path)
            }
            if FileManager.default.fileExists(atPath: destination.path),
               DahliaWorkspaceFileIdentity.resolve(destination) == sourceIdentity {
                destinationBySource[sourceIdentity] = destination
                continue
            }
            destinationBySource[sourceIdentity] = destination
            moves.append(SummaryFileMove(source: source, destination: destination))
        }
        return SummaryMovePlan(moves: moves, updates: updates)
    }

    func validateOutputDirectory(_ directory: URL, vaultURL: URL) throws {
        let root = vaultURL.standardizedFileURL
        let candidate = directory.standardizedFileURL
        let rootComponents = root.pathComponents
        guard candidate.pathComponents.starts(with: rootComponents) else {
            throw MeetingAccessError.projectFileConflict(candidate.path)
        }
        var current = root
        for component in candidate.pathComponents.dropFirst(rootComponents.count) {
            current.append(path: component, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: current.path) else {
                guard isInsideVaultOrRoot(current, vaultURL: root) else {
                    throw MeetingAccessError.projectFileConflict(current.path)
                }
                return
            }
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  isInsideVaultOrRoot(current, vaultURL: root) else {
                throw MeetingAccessError.projectFileConflict(current.path)
            }
        }
    }

    func destinationConflicts(
        _ destination: URL,
        sourceIdentity: DahliaWorkspaceFileIdentity
    ) throws -> Bool {
        let directory = destination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        let destinationKey = DahliaProjectName.siblingKey(destination.lastPathComponent)
        for entry in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) where DahliaProjectName.siblingKey(entry.lastPathComponent) == destinationKey {
            if DahliaWorkspaceFileIdentity.resolve(entry) != sourceIdentity {
                return true
            }
        }
        return false
    }

    func externalSummaryIdentities(
        excluding meetingIDs: Set<UUID>,
        vaultURL: URL,
        in db: Database
    ) throws -> Set<DahliaWorkspaceFileIdentity> {
        let placeholders = meetingIDs.map { _ in "?" }.joined(separator: ",")
        var arguments: StatementArguments = [vaultID]
        arguments += StatementArguments(meetingIDs)
        let urls = try String.fetchAll(
            db,
            sql: """
            SELECT summary_exports.url
            FROM summary_exports
            JOIN meetings ON meetings.id = summary_exports.meetingId
            WHERE summary_exports.type = 'vault'
              AND meetings.vaultId = ?
              AND summary_exports.meetingId NOT IN (\(placeholders))
            """,
            arguments: arguments
        )
        return Set(urls.compactMap { storedURL in
            guard let relativePath = vaultRelativeSummaryPath(storedURL) else { return nil }
            let source = vaultURL.appending(path: relativePath).standardizedFileURL
            guard isInsideVault(source, vaultURL: vaultURL) else { return nil }
            guard FileManager.default.fileExists(atPath: source.path) else { return nil }
            return DahliaWorkspaceFileIdentity.resolve(source)
        })
    }

    func createOutputDirectories(
        for moves: [SummaryFileMove],
        vaultURL: URL
    ) throws -> [URL] {
        let root = vaultURL.standardizedFileURL
        let directories = Set(moves.map { $0.destination.deletingLastPathComponent().standardizedFileURL })
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        var created: [URL] = []
        do {
            for directory in directories {
                try validateOutputDirectory(directory, vaultURL: root)
                var current = root
                for component in directory.pathComponents.dropFirst(root.pathComponents.count) {
                    current.append(path: component, directoryHint: .isDirectory)
                    guard !FileManager.default.fileExists(atPath: current.path) else { continue }
                    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
                    created.append(current)
                }
            }
            return created
        } catch {
            var rollbackFailed = false
            for directory in created.reversed() {
                do {
                    try removeNewEmptyDirectory(directory)
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

    func isInsideVaultOrRoot(_ value: URL, vaultURL: URL) -> Bool {
        value.resolvingSymlinksInPath().standardizedFileURL == vaultURL.resolvingSymlinksInPath().standardizedFileURL
            || isInsideVault(value, vaultURL: vaultURL)
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
