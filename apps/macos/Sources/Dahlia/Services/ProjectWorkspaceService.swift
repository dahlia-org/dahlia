import DahliaRuntimeSupport
import Darwin
import Foundation

@MainActor
final class ProjectWorkspaceService {
    typealias TrashHandler = @MainActor (URL) throws -> URL
    typealias SummaryFileResolver = @Sendable (String?, URL) throws -> URL?
    typealias StagedAudioRestorer = @MainActor ([BatchAudioCleanupService.StagedFile]) throws -> Void

    private struct SummaryRelocation {
        let sourceURL: URL
        let destinationURL: URL
    }

    private struct TrashedSummary {
        let originalURL: URL
        let trashURL: URL
    }

    private struct MeetingMovePlan {
        let meetingIds: Set<UUID>
        let relocations: [SummaryRelocation]
        let workspaceExportUpdates: [MeetingRepository.MeetingWorkspaceExportUpdate]
    }

    private struct ProjectSummaryMovePlan {
        let relocations: [SummaryRelocation]
        let workspaceExportUpdates: [MeetingRepository.MeetingWorkspaceExportUpdate]
    }

    private nonisolated let repository: MeetingRepository
    private nonisolated let workspace: WorkspaceRecord
    private let managedAudioRootURL: URL
    private let fileManager: FileManager
    private let trashHandler: TrashHandler
    private nonisolated let summaryFileResolver: SummaryFileResolver
    private let stagedAudioRestorer: StagedAudioRestorer

    init(
        repository: MeetingRepository,
        workspace: WorkspaceRecord,
        managedAudioRootURL: URL = BatchAudioStorage.managedRootURL,
        fileManager: FileManager = .default,
        trashHandler: @escaping TrashHandler = ProjectWorkspaceService.moveToTrash,
        summaryFileResolver: @escaping SummaryFileResolver = ProjectWorkspaceService.resolveSummaryFile,
        stagedAudioRestorer: @escaping StagedAudioRestorer = BatchAudioCleanupService.restoreStagedFiles
    ) {
        self.repository = repository
        self.workspace = workspace
        self.managedAudioRootURL = managedAudioRootURL
        self.fileManager = fileManager
        self.trashHandler = trashHandler
        self.summaryFileResolver = summaryFileResolver
        self.stagedAudioRestorer = stagedAudioRestorer
    }

    func createProject(
        name: String,
        parentProjectId: UUID?,
        projectType: ProjectType? = nil,
        description: String = "",
        appearance: ProjectAppearance? = nil
    ) throws -> ProjectRecord {
        try withNotifyingMutation {
            try createProjectUnlocked(
                name: name,
                parentProjectId: parentProjectId,
                projectType: projectType,
                description: description,
                appearance: appearance
            )
        }
    }

    func fetchOrCreateRootProject(name: String) throws -> ProjectRecord {
        let name = try Self.validatedName(name)
        let (project, changed) = try withMutationLock {
            let projects = try repository.fetchAllProjects(workspaceId: workspace.id)
            if let existing = projects.first(where: {
                $0.parentProjectId == nil
                    && DahliaProjectName.siblingKey($0.name) == DahliaProjectName.siblingKey(name)
            }) {
                return (existing, false)
            }

            let project = try createProjectUnlocked(name: name, parentProjectId: nil)
            return (project, true)
        }
        if changed {
            DahliaWorkspaceChangeNotification.post(workspaceID: workspace.id)
        }
        return project
    }

    private func createProjectUnlocked(
        name: String,
        parentProjectId: UUID?,
        projectType: ProjectType? = nil,
        description: String = "",
        appearance: ProjectAppearance? = nil
    ) throws -> ProjectRecord {
        let name = try Self.validatedName(name)
        let parent = try parentProjectId.map { id in
            guard let project = try repository.fetchProject(id: id), project.workspaceId == workspace.id else {
                throw ProjectWorkspaceError.projectNotFound
            }
            guard project.parentProjectId == nil else {
                throw ProjectWorkspaceError.hierarchyTooDeep
            }
            return project
        }
        if parent != nil, projectType != nil {
            throw ProjectWorkspaceError.typeOwnedByRoot
        }
        return try repository.createProject(
            workspaceId: workspace.id,
            parentProjectId: parentProjectId,
            name: name,
            description: description,
            projectType: projectType,
            appearance: appearance
        )
    }

    func renameProject(
        id: UUID,
        newName: String,
        expectedRevision: Int? = nil
    ) throws -> ProjectRecord {
        try withNotifyingMutation {
            try renameProjectUnlocked(
                id: id,
                newName: newName,
                expectedRevision: expectedRevision
            )
        }
    }

    private func renameProjectUnlocked(
        id: UUID,
        newName: String,
        expectedRevision: Int?
    ) throws -> ProjectRecord {
        guard let project = try repository.fetchProject(id: id), project.workspaceId == workspace.id else {
            throw ProjectWorkspaceError.projectNotFound
        }
        if let expectedRevision, project.revision != expectedRevision {
            throw ProjectWorkspaceError.staleRevision(current: project.revision)
        }
        let newName = try Self.validatedName(newName)
        guard newName != project.name else { return project }

        let parentPath = project.path.split(separator: "/").dropLast().joined(separator: "/")
        let newPath = parentPath.isEmpty ? newName : "\(parentPath)/\(newName)"
        let summaryPlan = try projectSummaryMovePlan(
            projectId: id,
            oldPrefix: project.path,
            newPrefix: newPath
        )
        var renamed: ProjectRecord?
        try performSummaryRelocations(summaryPlan.relocations) {
            renamed = try repository.updateProjectLocation(
                id: id,
                workspaceId: workspace.id,
                parentProjectId: project.parentProjectId,
                name: newName,
                workspaceExportUpdates: summaryPlan.workspaceExportUpdates,
                expectedRevision: expectedRevision
            )
        }
        guard let renamed else { throw ProjectWorkspaceError.projectNotFound }
        return renamed
    }

    func reparentProject(
        id: UUID,
        parentProjectId: UUID?,
        expectedRevision: Int? = nil
    ) throws -> ProjectRecord {
        try withNotifyingMutation {
            try reparentProjectUnlocked(
                id: id,
                parentProjectId: parentProjectId,
                expectedRevision: expectedRevision
            )
        }
    }

    private func reparentProjectUnlocked(
        id: UUID,
        parentProjectId: UUID?,
        expectedRevision: Int?
    ) throws -> ProjectRecord {
        guard let project = try repository.fetchProject(id: id), project.workspaceId == workspace.id else {
            throw ProjectWorkspaceError.projectNotFound
        }
        if let expectedRevision, project.revision != expectedRevision {
            throw ProjectWorkspaceError.staleRevision(current: project.revision)
        }
        guard project.parentProjectId != parentProjectId else { return project }

        let projects = try repository.fetchAllProjects(workspaceId: workspace.id)
        let descendantIds = Set(ProjectRecord.hierarchy(projectId: id, records: projects).dropFirst().map(\.id))
        guard parentProjectId != id,
              parentProjectId.map({ !descendantIds.contains($0) }) ?? true else {
            throw ProjectWorkspaceError.cycleDetected
        }

        let parent = try parentProjectId.map { parentId in
            guard let parent = projects.first(where: { $0.id == parentId }),
                  parent.workspaceId == workspace.id else {
                throw ProjectWorkspaceError.projectNotFound
            }
            guard parent.parentProjectId == nil else {
                throw ProjectWorkspaceError.hierarchyTooDeep
            }
            return parent
        }
        if parent != nil, !descendantIds.isEmpty {
            throw ProjectWorkspaceError.hierarchyTooDeep
        }
        let newPath = parent.map { "\($0.path)/\(project.name)" } ?? project.name
        let summaryPlan = try projectSummaryMovePlan(
            projectId: id,
            oldPrefix: project.path,
            newPrefix: newPath
        )
        var moved: ProjectRecord?
        try performSummaryRelocations(summaryPlan.relocations) {
            moved = try repository.updateProjectLocation(
                id: id,
                workspaceId: workspace.id,
                parentProjectId: parentProjectId,
                name: project.name,
                workspaceExportUpdates: summaryPlan.workspaceExportUpdates,
                expectedRevision: expectedRevision
            )
        }
        guard let moved else { throw ProjectWorkspaceError.projectNotFound }
        return moved
    }

    func updateRootProjectType(
        id: UUID,
        projectType: ProjectType,
        expectedRevision: Int? = nil
    ) throws -> ProjectRecord {
        try withNotifyingMutation {
            guard let project = try repository.fetchProject(id: id), project.workspaceId == workspace.id else {
                throw ProjectWorkspaceError.projectNotFound
            }
            return try repository.updateRootProjectType(
                id: id,
                workspaceId: workspace.id,
                projectType: projectType,
                expectedRevision: expectedRevision
            )
        }
    }

    nonisolated func updateProject(
        id: UUID,
        name: String,
        parentProjectId: UUID?,
        projectType: ProjectType,
        description: String,
        expectedRevision: Int,
        appearance: ProjectAppearance? = nil
    ) throws -> ProjectRecord {
        try withNotifyingMutation {
            guard let project = try repository.fetchProject(id: id), project.workspaceId == workspace.id else {
                throw ProjectWorkspaceError.projectNotFound
            }
            guard project.revision == expectedRevision else {
                throw ProjectWorkspaceError.staleRevision(current: project.revision)
            }
            let name = try Self.validatedName(name)
            let projects = try repository.fetchAllProjects(workspaceId: workspace.id)
            let descendants = Array(ProjectRecord.hierarchy(projectId: id, records: projects).dropFirst())
            let descendantIDs = Set(descendants.map(\.id))
            guard parentProjectId != id,
                  parentProjectId.map({ !descendantIDs.contains($0) }) ?? true else {
                throw ProjectWorkspaceError.cycleDetected
            }
            let parent = try parentProjectId.map { parentID in
                guard let parent = projects.first(where: { $0.id == parentID }) else {
                    throw ProjectWorkspaceError.projectNotFound
                }
                guard parent.parentProjectId == nil, descendants.isEmpty else {
                    throw ProjectWorkspaceError.hierarchyTooDeep
                }
                return parent
            }
            let newPath = parent.map { "\($0.path)/\(name)" } ?? name
            let summaryPlan = if project.path == newPath {
                ProjectSummaryMovePlan(relocations: [], workspaceExportUpdates: [])
            } else {
                try projectSummaryMovePlan(
                    projectId: id,
                    oldPrefix: project.path,
                    newPrefix: newPath
                )
            }
            return try performSummaryRelocations(summaryPlan.relocations) {
                try repository.updateProject(
                    id: id,
                    workspaceId: workspace.id,
                    parentProjectId: parentProjectId,
                    name: name,
                    description: description,
                    projectType: projectType,
                    workspaceExportUpdates: summaryPlan.workspaceExportUpdates,
                    expectedRevision: expectedRevision,
                    appearance: appearance
                )
            }
        }
    }

    func updateProjectDescription(
        id: UUID,
        description: String,
        expectedRevision: Int? = nil
    ) throws -> Bool {
        let changed = try withMutationLock {
            guard let project = try repository.fetchProject(id: id), project.workspaceId == workspace.id else {
                throw ProjectWorkspaceError.projectNotFound
            }
            if let expectedRevision, project.revision != expectedRevision {
                throw ProjectWorkspaceError.staleRevision(current: project.revision)
            }
            return try repository.updateProjectDescription(
                id: id,
                workspaceId: workspace.id,
                description: description,
                expectedRevision: expectedRevision
            )
        }
        if changed {
            DahliaWorkspaceChangeNotification.post(workspaceID: workspace.id)
        }
        return changed
    }

    func moveMeeting(id: UUID, toProjectId: UUID?) throws {
        try moveMeetings(ids: [id], toProjectId: toProjectId)
    }

    func moveMeetings(ids: Set<UUID>, toProjectId: UUID?) throws {
        let changed = try withMutationLock {
            try moveMeetingsUnlocked(ids: ids, toProjectId: toProjectId)
        }
        if changed {
            DahliaWorkspaceChangeNotification.post(workspaceID: workspace.id)
        }
    }

    private func moveMeetingsUnlocked(ids: Set<UUID>, toProjectId: UUID?) throws -> Bool {
        let plan = try makeMeetingMovePlan(ids: ids, toProjectId: toProjectId)
        guard !plan.meetingIds.isEmpty else { return false }

        try performSummaryRelocations(plan.relocations) {
            try repository.commitMeetingMove(
                ids: plan.meetingIds,
                toProjectId: toProjectId,
                workspaceId: workspace.id,
                workspaceExportUpdates: plan.workspaceExportUpdates
            )
        }
        return true
    }

    func deleteProjectHierarchy(
        id: UUID,
        meetingDisposition: ProjectMeetingDisposition,
        deletesSummaryFiles: Bool = false
    ) async throws {
        let stagedAudio = try withMutationLock {
            try deleteProjectHierarchyUnlocked(
                id: id,
                meetingDisposition: meetingDisposition,
                deletesSummaryFiles: deletesSummaryFiles
            )
        }
        DahliaWorkspaceChangeNotification.post(workspaceID: workspace.id)
        try BatchAudioCleanupService.discardStagedFiles(stagedAudio)
    }

    private func deleteProjectHierarchyUnlocked(
        id: UUID,
        meetingDisposition: ProjectMeetingDisposition,
        deletesSummaryFiles: Bool
    ) throws -> [BatchAudioCleanupService.StagedFile] {
        guard let project = try repository.fetchProject(id: id), project.workspaceId == workspace.id else {
            throw ProjectWorkspaceError.projectNotFound
        }

        let movePlan: MeetingMovePlan?
        if case let .move(destinationId) = meetingDisposition {
            let hierarchyIds = try Set(
                ProjectRecord.hierarchy(
                    projectId: id,
                    records: repository.fetchAllProjects(workspaceId: workspace.id)
                ).map(\.id)
            )
            guard let destination = try repository.fetchProject(id: destinationId),
                  destination.workspaceId == workspace.id,
                  !hierarchyIds.contains(destinationId)
            else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
            let hierarchyMeetingIds = try repository.meetingIds(projectHierarchy: id, workspaceId: workspace.id)
            movePlan = try makeMeetingMovePlan(ids: hierarchyMeetingIds, toProjectId: destinationId)
        } else {
            movePlan = nil
        }

        let trashedSummaries = meetingDisposition == .deleteMeetings && deletesSummaryFiles
            ? try trashTrackedSummaries(projectId: id)
            : []
        let relocations = movePlan?.relocations ?? []
        let stagedAudio: [BatchAudioCleanupService.StagedFile]
        do {
            stagedAudio = try performSummaryRelocations(relocations) {
                try repository.deleteProjectHierarchy(
                    projectId: id,
                    workspaceId: workspace.id,
                    meetingDisposition: meetingDisposition,
                    workspaceExportUpdates: movePlan?.workspaceExportUpdates ?? [],
                    managedAudioRootURL: managedAudioRootURL,
                    restoreStagedAudio: stagedAudioRestorer
                )
            }
        } catch {
            try restoreTrashedSummaries(trashedSummaries)
            throw error
        }
        return stagedAudio
    }

    private func trashTrackedSummaries(projectId: UUID) throws -> [TrashedSummary] {
        guard let workspaceURL = workspace.url else { return [] }
        let meetingIds = try repository.meetingIds(projectHierarchy: projectId, workspaceId: workspace.id)
        guard !meetingIds.isEmpty else { return [] }
        let candidates = try repository.fetchMeetingMoveCandidates(ids: meetingIds, workspaceId: workspace.id)
        let externalPaths = try repository.externalWorkspaceSummaryPaths(
            movingMeetingIds: meetingIds,
            workspaceId: workspace.id
        )
        let externalIdentities = try Set(externalPaths.compactMap {
            try summaryFileResolver($0, workspaceURL).map {
                DahliaWorkspaceFileIdentity.resolve($0, fileManager: fileManager)
            }
        })
        var trashed: [TrashedSummary] = []
        var handled: Set<DahliaWorkspaceFileIdentity> = []
        do {
            for candidate in candidates where candidate.hasWorkspaceExport {
                guard let source = try summaryFileResolver(candidate.workspaceRelativePath, workspaceURL) else { continue }
                guard isInsideWorkspaceAfterResolvingSymlinks(source),
                      pathContainsNoSymlinks(source) else {
                    throw ProjectWorkspaceError.invalidMoveDestination
                }
                let identity = DahliaWorkspaceFileIdentity.resolve(source, fileManager: fileManager)
                guard handled.insert(identity).inserted else { continue }
                guard !externalIdentities.contains(identity) else {
                    throw ProjectWorkspaceError.summaryFileShared(source.lastPathComponent)
                }
                try trashed.append(TrashedSummary(originalURL: source, trashURL: trashHandler(source)))
            }
            return trashed
        } catch {
            try restoreTrashedSummaries(trashed)
            throw error
        }
    }

    private func restoreTrashedSummaries(_ summaries: [TrashedSummary]) throws {
        var firstError: Error?
        for summary in summaries.reversed() {
            do {
                try fileManager.moveItem(at: summary.trashURL, to: summary.originalURL)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw ProjectWorkspaceError.rollbackFailed(
                operation: L10n.projectOperationFailed,
                rollback: firstError.localizedDescription
            )
        }
    }

    nonisolated static func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.utf8.count <= 255 else { throw ProjectWorkspaceError.nameTooLong }
        guard DahliaProjectName.normalizedName(name) == name else {
            throw ProjectWorkspaceError.invalidName
        }
        return name
    }
}

extension ProjectWorkspaceService {
    private nonisolated func withNotifyingMutation<T>(_ operation: () throws -> T) throws -> T {
        let result = try withMutationLock(operation)
        DahliaWorkspaceChangeNotification.post(workspaceID: workspace.id)
        return result
    }

    private nonisolated func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        guard let workspaceURL = workspace.url else { return try operation() }
        do {
            return try DahliaWorkspaceMutationLock.withLock(
                workspaceURL: workspaceURL,
                workspaceID: workspace.id,
                operation: operation
            )
        } catch is DahliaWorkspaceMutationLockError {
            throw ProjectWorkspaceError.workspaceBusy
        }
    }

    private func projectURL(path: String) throws -> URL {
        guard let workspaceURL = workspace.url else { throw ProjectWorkspaceError.invalidMoveDestination }
        return workspaceURL.appending(path: path, directoryHint: .isDirectory)
    }

    private func makeMeetingMovePlan(ids: Set<UUID>, toProjectId: UUID?) throws -> MeetingMovePlan {
        guard !ids.isEmpty else {
            return MeetingMovePlan(meetingIds: [], relocations: [], workspaceExportUpdates: [])
        }

        let candidates = try repository.fetchMeetingMoveCandidates(ids: ids, workspaceId: workspace.id)
            .filter { $0.projectId != toProjectId }
        guard !candidates.isEmpty else {
            return MeetingMovePlan(meetingIds: [], relocations: [], workspaceExportUpdates: [])
        }
        let meetingIds = Set(candidates.map(\.meetingId))
        guard let workspaceURL = workspace.url else {
            return MeetingMovePlan(meetingIds: meetingIds, relocations: [], workspaceExportUpdates: [])
        }
        let destinationDirectory = try summaryDestinationDirectory(toProjectId: toProjectId)
        let externalSummaryPaths = try repository.externalWorkspaceSummaryPaths(
            movingMeetingIds: meetingIds,
            workspaceId: workspace.id
        )
        let externallyReferencedSources = try Set(externalSummaryPaths.compactMap { relativePath
                -> DahliaWorkspaceFileIdentity? in
            guard let url = try summaryFileResolver(relativePath, workspaceURL) else { return nil }
            return DahliaWorkspaceFileIdentity.resolve(url, fileManager: fileManager)
        })
        var relocations: [SummaryRelocation] = []
        var updates: [MeetingRepository.MeetingWorkspaceExportUpdate] = []
        var destinationPaths: Set<String> = []
        var destinationBySource: [DahliaWorkspaceFileIdentity: URL] = [:]

        for candidate in candidates where candidate.hasWorkspaceExport {
            guard let sourceURL = try summaryFileResolver(candidate.workspaceRelativePath, workspaceURL) else {
                updates.append(.init(meetingId: candidate.meetingId, relativePath: nil))
                continue
            }
            guard isInsideWorkspaceAfterResolvingSymlinks(sourceURL),
                  pathContainsNoSymlinks(sourceURL) else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }

            try validateOutputDirectory(destinationDirectory)
            let destinationURL = destinationDirectory
                .appending(path: sourceURL.lastPathComponent, directoryHint: .notDirectory)
                .standardizedFileURL
            let standardizedSourceURL = sourceURL.standardizedFileURL
            guard let relativePath = WorkspaceSummaryFileLocator.relativePath(
                for: destinationURL,
                workspaceURL: workspaceURL
            ) else {
                updates.append(.init(meetingId: candidate.meetingId, relativePath: nil))
                continue
            }

            updates.append(.init(meetingId: candidate.meetingId, relativePath: relativePath))
            guard standardizedSourceURL != destinationURL else { continue }

            let sourceIdentity = DahliaWorkspaceFileIdentity.resolve(
                standardizedSourceURL,
                fileManager: fileManager
            )
            guard !externallyReferencedSources.contains(sourceIdentity) else {
                throw ProjectWorkspaceError.summaryFileShared(sourceURL.lastPathComponent)
            }
            if let plannedDestination = destinationBySource[sourceIdentity] {
                guard plannedDestination == destinationURL else {
                    throw ProjectWorkspaceError.summaryFileAlreadyExists(destinationURL.lastPathComponent)
                }
                continue
            }

            let destinationKey = DahliaProjectName.siblingKey(destinationURL.path)
            let conflictsWithExistingFile = try destinationConflicts(
                destinationURL,
                sourceIdentity: sourceIdentity
            )
            if !destinationPaths.insert(destinationKey).inserted
                || conflictsWithExistingFile {
                throw ProjectWorkspaceError.summaryFileAlreadyExists(destinationURL.lastPathComponent)
            }
            if fileManager.fileExists(atPath: destinationURL.path),
               DahliaWorkspaceFileIdentity.resolve(destinationURL, fileManager: fileManager) == sourceIdentity {
                destinationBySource[sourceIdentity] = destinationURL
                continue
            }
            destinationBySource[sourceIdentity] = destinationURL
            relocations.append(.init(sourceURL: standardizedSourceURL, destinationURL: destinationURL))
        }

        return MeetingMovePlan(
            meetingIds: meetingIds,
            relocations: relocations,
            workspaceExportUpdates: updates
        )
    }

    private func summaryDestinationDirectory(toProjectId: UUID?) throws -> URL {
        let destinationDirectory: URL
        if let toProjectId {
            guard let destination = try repository.fetchProject(id: toProjectId),
                  destination.workspaceId == workspace.id
            else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
            destinationDirectory = try projectURL(path: destination.path)
        } else {
            guard let workspaceURL = workspace.url else { throw ProjectWorkspaceError.invalidMoveDestination }
            destinationDirectory = workspaceURL
        }
        return destinationDirectory
    }

    private nonisolated func projectSummaryMovePlan(
        projectId: UUID,
        oldPrefix: String,
        newPrefix: String
    ) throws -> ProjectSummaryMovePlan {
        guard let workspaceURL = workspace.url else {
            return ProjectSummaryMovePlan(relocations: [], workspaceExportUpdates: [])
        }
        let fileManager = FileManager.default
        let meetingIds = try repository.meetingIds(projectHierarchy: projectId, workspaceId: workspace.id)
        guard !meetingIds.isEmpty else {
            return ProjectSummaryMovePlan(relocations: [], workspaceExportUpdates: [])
        }
        let candidates = try repository.fetchMeetingMoveCandidates(ids: meetingIds, workspaceId: workspace.id)
        let projects = try repository.fetchAllProjects(workspaceId: workspace.id)
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let protectedIdentities = try protectedProjectSummaryIdentities(
            candidates: candidates,
            projectPaths: projectPaths,
            meetingIds: meetingIds
        )

        var relocations: [SummaryRelocation] = []
        var updates: [MeetingRepository.MeetingWorkspaceExportUpdate] = []
        var destinations: Set<String> = []
        var destinationBySource: [DahliaWorkspaceFileIdentity: URL] = [:]
        for candidate in candidates where candidate.hasWorkspaceExport {
            guard let projectId = candidate.projectId,
                  let oldProjectPath = projectPaths[projectId] else { continue }
            let newProjectPath = oldProjectPath == oldPrefix
                ? newPrefix
                : newPrefix + oldProjectPath.dropFirst(oldPrefix.count)
            guard let storedPath = candidate.workspaceRelativePath else {
                updates.append(.init(meetingId: candidate.meetingId, relativePath: nil))
                continue
            }
            let oldDirectoryPrefix = oldProjectPath + "/"
            guard storedPath.hasPrefix(oldDirectoryPrefix) else {
                // Legacy exports that do not follow the derived Project path remain at their stored location.
                continue
            }
            let suffix = storedPath.dropFirst(oldDirectoryPrefix.count)
            guard !suffix.isEmpty else {
                updates.append(.init(meetingId: candidate.meetingId, relativePath: nil))
                continue
            }
            let destinationRelativePath = "\(newProjectPath)/\(suffix)"
            guard let resolvedSourceURL = try summaryFileResolver(storedPath, workspaceURL) else {
                updates.append(.init(meetingId: candidate.meetingId, relativePath: nil))
                continue
            }
            guard isInsideWorkspaceAfterResolvingSymlinks(resolvedSourceURL),
                  pathContainsNoSymlinks(resolvedSourceURL) else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
            let destinationURL = workspaceURL
                .appending(path: destinationRelativePath, directoryHint: .notDirectory)
                .standardizedFileURL
            try validateOutputDirectory(destinationURL.deletingLastPathComponent())
            updates.append(.init(
                meetingId: candidate.meetingId,
                relativePath: destinationRelativePath
            ))
            let sourceURL = resolvedSourceURL.standardizedFileURL
            guard sourceURL != destinationURL else { continue }

            let sourceIdentity = DahliaWorkspaceFileIdentity.resolve(sourceURL, fileManager: fileManager)
            guard !protectedIdentities.contains(sourceIdentity) else {
                throw ProjectWorkspaceError.summaryFileShared(sourceURL.lastPathComponent)
            }
            if let existingDestination = destinationBySource[sourceIdentity] {
                guard existingDestination == destinationURL else {
                    throw ProjectWorkspaceError.summaryFileAlreadyExists(destinationURL.lastPathComponent)
                }
                continue
            }
            let destinationKey = DahliaProjectName.siblingKey(destinationURL.path)
            guard destinations.insert(destinationKey).inserted,
                  try !destinationConflicts(
                      destinationURL,
                      sourceIdentity: sourceIdentity
                  ) else {
                throw ProjectWorkspaceError.summaryFileAlreadyExists(destinationURL.lastPathComponent)
            }
            if fileManager.fileExists(atPath: destinationURL.path),
               DahliaWorkspaceFileIdentity.resolve(destinationURL, fileManager: fileManager) == sourceIdentity {
                destinationBySource[sourceIdentity] = destinationURL
                continue
            }
            destinationBySource[sourceIdentity] = destinationURL
            relocations.append(.init(sourceURL: sourceURL, destinationURL: destinationURL))
        }
        return ProjectSummaryMovePlan(
            relocations: relocations,
            workspaceExportUpdates: updates
        )
    }

    private nonisolated func protectedProjectSummaryIdentities(
        candidates: [MeetingRepository.MeetingMoveCandidate],
        projectPaths: [UUID: String],
        meetingIds: Set<UUID>
    ) throws -> Set<DahliaWorkspaceFileIdentity> {
        guard let workspaceURL = workspace.url else { return [] }
        let fileManager = FileManager.default
        let externalPaths = try repository.externalWorkspaceSummaryPaths(
            movingMeetingIds: meetingIds,
            workspaceId: workspace.id
        )
        let externalIdentities = try Set(externalPaths.compactMap {
            try summaryFileResolver($0, workspaceURL).map {
                DahliaWorkspaceFileIdentity.resolve($0, fileManager: fileManager)
            }
        })
        let retainedIdentities: Set<DahliaWorkspaceFileIdentity> = try Set(candidates.compactMap { candidate in
            guard candidate.hasWorkspaceExport,
                  let projectId = candidate.projectId,
                  let projectPath = projectPaths[projectId],
                  let storedPath = candidate.workspaceRelativePath,
                  !storedPath.hasPrefix(projectPath + "/"),
                  let sourceURL = try summaryFileResolver(storedPath, workspaceURL)
            else {
                return nil
            }
            return DahliaWorkspaceFileIdentity.resolve(sourceURL, fileManager: fileManager)
        })
        return externalIdentities.union(retainedIdentities)
    }

    private nonisolated func validateOutputDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        guard let root = workspace.url?.standardizedFileURL else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }
        let candidate = directory.standardizedFileURL
        let rootComponents = root.pathComponents
        guard candidate.pathComponents.starts(with: rootComponents) else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }

        var current = root
        for component in candidate.pathComponents.dropFirst(rootComponents.count) {
            current.append(path: component, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: current.path) else {
                guard isInsideWorkspaceAfterResolvingSymlinks(current) else {
                    throw ProjectWorkspaceError.invalidMoveDestination
                }
                return
            }
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  isInsideWorkspaceAfterResolvingSymlinks(current) else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
        }
        guard isDirectoryInsideWorkspace(candidate) else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }
    }

    private nonisolated func destinationConflicts(
        _ destination: URL,
        sourceIdentity: DahliaWorkspaceFileIdentity
    ) throws -> Bool {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        let destinationKey = DahliaProjectName.siblingKey(destination.lastPathComponent)
        for entry in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) where DahliaProjectName.siblingKey(entry.lastPathComponent) == destinationKey {
            if DahliaWorkspaceFileIdentity.resolve(entry, fileManager: fileManager) != sourceIdentity {
                return true
            }
        }
        return false
    }

    private nonisolated func isDirectoryInsideWorkspace(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && isInsideWorkspaceAfterResolvingSymlinks(url)
            && pathContainsNoSymlinks(url)
    }

    private nonisolated func isInsideWorkspaceAfterResolvingSymlinks(_ url: URL) -> Bool {
        guard let workspacePath = workspace.url?.resolvingSymlinksInPath().standardizedFileURL.path else { return false }
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
        return candidatePath == workspacePath || candidatePath.hasPrefix(prefix)
    }

    private nonisolated func pathContainsNoSymlinks(_ url: URL) -> Bool {
        guard let root = workspace.url?.standardizedFileURL else { return false }
        let candidate = url.standardizedFileURL
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.starts(with: rootComponents) else { return false }

        var current = root
        for component in candidateComponents.dropFirst(rootComponents.count) {
            current.append(path: component)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                return false
            }
        }
        return true
    }

    nonisolated static func resolveSummaryFile(storedRelativePath: String?, workspaceURL: URL) throws -> URL? {
        guard let storedRelativePath,
              let fileURL = WorkspaceSummaryFileLocator.fileURL(for: storedRelativePath, workspaceURL: workspaceURL),
              fileURL.pathExtension.lowercased() == "md"
        else { return nil }

        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true ? fileURL : nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
    }

    /// File system and SQLite operations cannot share a transaction. Runtime failures are compensated here.
    private nonisolated func performSummaryRelocations<Result>(
        _ relocations: [SummaryRelocation],
        operation: () throws -> Result
    ) throws -> Result {
        guard !relocations.isEmpty else { return try operation() }
        guard let workspaceURL = workspace.url else { throw ProjectWorkspaceError.invalidMoveDestination }
        let createdDirectories = try createOutputDirectories(for: relocations)
        var completed: [SummaryRelocation] = []
        do {
            for relocation in relocations {
                try DahliaWorkspaceFileMover.moveItem(
                    at: relocation.sourceURL,
                    to: relocation.destinationURL,
                    inside: workspaceURL
                )
                completed.append(relocation)
            }
            return try operation()
        } catch let operationError {
            var rollbackError: (any Error)?
            for relocation in completed.reversed() {
                do {
                    try DahliaWorkspaceFileMover.moveItem(
                        at: relocation.destinationURL,
                        to: relocation.sourceURL,
                        inside: workspaceURL
                    )
                } catch {
                    rollbackError = rollbackError ?? error
                }
            }
            for directory in createdDirectories.reversed() {
                do {
                    try removeNewEmptyDirectory(directory)
                } catch {
                    rollbackError = rollbackError ?? error
                }
            }
            if let rollbackError {
                throw ProjectWorkspaceError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw operationError
        }
    }

    private nonisolated func createOutputDirectories(for relocations: [SummaryRelocation]) throws -> [URL] {
        guard !relocations.isEmpty else { return [] }
        guard let workspaceURL = workspace.url else { throw ProjectWorkspaceError.invalidMoveDestination }
        let fileManager = FileManager.default
        let directories = Set(relocations.map { $0.destinationURL.deletingLastPathComponent().standardizedFileURL })
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        var created: [URL] = []
        do {
            for directory in directories {
                try validateOutputDirectory(directory)
                let root = workspaceURL.standardizedFileURL
                var current = root
                for component in directory.pathComponents.dropFirst(root.pathComponents.count) {
                    current.append(path: component, directoryHint: .isDirectory)
                    guard !fileManager.fileExists(atPath: current.path) else { continue }
                    try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
                    created.append(current)
                }
            }
            return created
        } catch let operationError {
            var rollbackError: (any Error)?
            for directory in created.reversed() {
                do {
                    try removeNewEmptyDirectory(directory)
                } catch {
                    rollbackError = rollbackError ?? error
                }
            }
            if let rollbackError {
                throw ProjectWorkspaceError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw operationError
        }
    }

    private nonisolated func removeNewEmptyDirectory(_ url: URL) throws {
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.rmdir(path)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func moveToTrash(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else { throw ProjectWorkspaceError.trashLocationUnavailable }
        return resultingURL as URL
    }
}
