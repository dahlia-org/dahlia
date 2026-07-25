import DahliaRuntimeSupport
import Darwin
import Foundation

@MainActor
final class ProjectWorkspaceService {
    typealias TrashHandler = @MainActor (URL) throws -> URL
    typealias SummaryFileResolver = @MainActor (String?, URL) throws -> URL?

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
        let vaultExportUpdates: [MeetingRepository.MeetingVaultExportUpdate]
    }

    private struct ProjectSummaryMovePlan {
        let relocations: [SummaryRelocation]
        let vaultExportUpdates: [MeetingRepository.MeetingVaultExportUpdate]
    }

    private let repository: MeetingRepository
    private let vault: VaultRecord
    private let managedAudioRootURL: URL
    private let fileManager: FileManager
    private let trashHandler: TrashHandler
    private let summaryFileResolver: SummaryFileResolver

    init(
        repository: MeetingRepository,
        vault: VaultRecord,
        managedAudioRootURL: URL = BatchAudioStorage.managedRootURL,
        fileManager: FileManager = .default,
        trashHandler: @escaping TrashHandler = ProjectWorkspaceService.moveToTrash,
        summaryFileResolver: @escaping SummaryFileResolver = ProjectWorkspaceService.resolveSummaryFile
    ) {
        self.repository = repository
        self.vault = vault
        self.managedAudioRootURL = managedAudioRootURL
        self.fileManager = fileManager
        self.trashHandler = trashHandler
        self.summaryFileResolver = summaryFileResolver
    }

    func createProject(
        leafName: String,
        parentProjectId: UUID?,
        projectType: ProjectType? = nil,
        description: String = ""
    ) throws -> ProjectRecord {
        try withNotifyingMutation {
            try createProjectUnlocked(
                leafName: leafName,
                parentProjectId: parentProjectId,
                projectType: projectType,
                description: description
            )
        }
    }

    func fetchOrCreateRootProject(leafName: String) throws -> ProjectRecord {
        let leafName = try Self.validatedLeafName(leafName)
        let (project, changed) = try withMutationLock {
            let projects = try repository.fetchAllProjects(vaultId: vault.id)
            if let existing = projects.first(where: {
                $0.parentProjectId == nil
                    && DahliaProjectName.siblingKey($0.leafName) == DahliaProjectName.siblingKey(leafName)
            }) {
                return (existing, false)
            }

            let project = try createProjectUnlocked(leafName: leafName, parentProjectId: nil)
            return (project, true)
        }
        if changed {
            DahliaWorkspaceChangeNotification.post(vaultID: vault.id)
        }
        return project
    }

    private func createProjectUnlocked(
        leafName: String,
        parentProjectId: UUID?,
        projectType: ProjectType? = nil,
        description: String = ""
    ) throws -> ProjectRecord {
        let leafName = try Self.validatedLeafName(leafName)
        let parent = try parentProjectId.map { id in
            guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
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
        let name = parent.map { "\($0.name)/\(leafName)" } ?? leafName
        try ensureProjectDoesNotExist(name: name, excludingProjectId: nil)
        return try repository.createProject(
            vaultId: vault.id,
            parentProjectId: parentProjectId,
            leafName: leafName,
            description: description,
            projectType: projectType
        )
    }

    func renameProject(
        id: UUID,
        newLeafName: String,
        expectedRevision: Int? = nil
    ) throws -> ProjectRecord {
        try withNotifyingMutation {
            try renameProjectUnlocked(
                id: id,
                newLeafName: newLeafName,
                expectedRevision: expectedRevision
            )
        }
    }

    private func renameProjectUnlocked(
        id: UUID,
        newLeafName: String,
        expectedRevision: Int?
    ) throws -> ProjectRecord {
        guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
            throw ProjectWorkspaceError.projectNotFound
        }
        if let expectedRevision, project.revision != expectedRevision {
            throw ProjectWorkspaceError.staleRevision(current: project.revision)
        }
        let newLeafName = try Self.validatedLeafName(newLeafName)
        guard newLeafName != project.leafName else { return project }

        let parentName = project.name.split(separator: "/").dropLast().joined(separator: "/")
        let newName = parentName.isEmpty ? newLeafName : "\(parentName)/\(newLeafName)"
        try ensureProjectDoesNotExist(name: newName, excludingProjectId: id)

        let summaryPlan = try projectSummaryMovePlan(oldPrefix: project.name, newPrefix: newName)
        var renamed: ProjectRecord?
        try performSummaryRelocations(summaryPlan.relocations) {
            renamed = try repository.updateProjectLocation(
                id: id,
                vaultId: vault.id,
                parentProjectId: project.parentProjectId,
                leafName: newLeafName,
                vaultExportUpdates: summaryPlan.vaultExportUpdates,
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
        guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
            throw ProjectWorkspaceError.projectNotFound
        }
        if let expectedRevision, project.revision != expectedRevision {
            throw ProjectWorkspaceError.staleRevision(current: project.revision)
        }
        guard project.parentProjectId != parentProjectId else { return project }

        let projects = try repository.fetchAllProjects(vaultId: vault.id)
        let descendantIds = Set(
            projects.filter { candidate in
                candidate.id != project.id
                    && ProjectRecord.belongsToHierarchy(candidate.name, prefix: project.name)
            }
            .map(\.id)
        )
        guard parentProjectId != id,
              parentProjectId.map({ !descendantIds.contains($0) }) ?? true else {
            throw ProjectWorkspaceError.cycleDetected
        }

        let parent = try parentProjectId.map { parentId in
            guard let parent = projects.first(where: { $0.id == parentId }),
                  parent.vaultId == vault.id else {
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
        let newName = parent.map { "\($0.name)/\(project.leafName)" } ?? project.leafName
        try ensureProjectDoesNotExist(name: newName, excludingProjectId: id)
        let summaryPlan = try projectSummaryMovePlan(oldPrefix: project.name, newPrefix: newName)
        var moved: ProjectRecord?
        try performSummaryRelocations(summaryPlan.relocations) {
            moved = try repository.updateProjectLocation(
                id: id,
                vaultId: vault.id,
                parentProjectId: parentProjectId,
                leafName: project.leafName,
                vaultExportUpdates: summaryPlan.vaultExportUpdates,
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
            guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
                throw ProjectWorkspaceError.projectNotFound
            }
            return try repository.updateRootProjectType(
                id: id,
                vaultId: vault.id,
                projectType: projectType,
                expectedRevision: expectedRevision
            )
        }
    }

    func updateProjectDescription(
        id: UUID,
        description: String,
        expectedRevision: Int? = nil
    ) throws -> Bool {
        let changed = try withMutationLock {
            guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
                throw ProjectWorkspaceError.projectNotFound
            }
            if let expectedRevision, project.revision != expectedRevision {
                throw ProjectWorkspaceError.staleRevision(current: project.revision)
            }
            return try repository.updateProjectDescription(
                id: id,
                vaultId: vault.id,
                description: description,
                expectedRevision: expectedRevision
            )
        }
        if changed {
            DahliaWorkspaceChangeNotification.post(vaultID: vault.id)
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
            DahliaWorkspaceChangeNotification.post(vaultID: vault.id)
        }
    }

    private func moveMeetingsUnlocked(ids: Set<UUID>, toProjectId: UUID?) throws -> Bool {
        let plan = try makeMeetingMovePlan(ids: ids, toProjectId: toProjectId)
        guard !plan.meetingIds.isEmpty else { return false }

        try performSummaryRelocations(plan.relocations) {
            try repository.commitMeetingMove(
                ids: plan.meetingIds,
                toProjectId: toProjectId,
                vaultId: vault.id,
                vaultExportUpdates: plan.vaultExportUpdates
            )
        }
        return true
    }

    func deleteProjectHierarchy(
        id: UUID,
        meetingDisposition: ProjectMeetingDisposition,
        deletesSummaryFiles: Bool = false
    ) async throws {
        try withNotifyingMutation {
            try deleteProjectHierarchyUnlocked(
                id: id,
                meetingDisposition: meetingDisposition,
                deletesSummaryFiles: deletesSummaryFiles
            )
        }
    }

    private func deleteProjectHierarchyUnlocked(
        id: UUID,
        meetingDisposition: ProjectMeetingDisposition,
        deletesSummaryFiles: Bool
    ) throws {
        guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
            throw ProjectWorkspaceError.projectNotFound
        }

        let movePlan: MeetingMovePlan?
        if case let .move(destinationId) = meetingDisposition {
            guard let destination = try repository.fetchProject(id: destinationId),
                  destination.vaultId == vault.id,
                  !ProjectRecord.belongsToHierarchy(destination.name, prefix: project.name)
            else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
            let hierarchyMeetingIds = try repository.meetingIds(projectHierarchy: project.name, vaultId: vault.id)
            movePlan = try makeMeetingMovePlan(ids: hierarchyMeetingIds, toProjectId: destinationId)
        } else {
            movePlan = nil
        }

        let trashedSummaries = meetingDisposition == .deleteMeetings && deletesSummaryFiles
            ? try trashTrackedSummaries(projectPath: project.name)
            : []
        let relocations = movePlan?.relocations ?? []
        do {
            try performSummaryRelocations(relocations) {
                try repository.deleteProjectHierarchy(
                    name: project.name,
                    vaultId: vault.id,
                    meetingDisposition: meetingDisposition,
                    vaultExportUpdates: movePlan?.vaultExportUpdates ?? [],
                    managedAudioRootURL: managedAudioRootURL
                )
            }
        } catch {
            try restoreTrashedSummaries(trashedSummaries)
            throw error
        }
    }

    private func trashTrackedSummaries(projectPath: String) throws -> [TrashedSummary] {
        let meetingIds = try repository.meetingIds(projectHierarchy: projectPath, vaultId: vault.id)
        guard !meetingIds.isEmpty else { return [] }
        let candidates = try repository.fetchMeetingMoveCandidates(ids: meetingIds, vaultId: vault.id)
        let externalPaths = try repository.externalVaultSummaryPaths(
            movingMeetingIds: meetingIds,
            vaultId: vault.id
        )
        let externalIdentities = try Set(externalPaths.compactMap {
            try summaryFileResolver($0, vault.url).map {
                DahliaWorkspaceFileIdentity.resolve($0, fileManager: fileManager)
            }
        })
        var trashed: [TrashedSummary] = []
        var handled: Set<DahliaWorkspaceFileIdentity> = []
        do {
            for candidate in candidates where candidate.hasVaultExport {
                guard let source = try summaryFileResolver(candidate.vaultRelativePath, vault.url) else { continue }
                guard isInsideVaultAfterResolvingSymlinks(source),
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

    static func validatedLeafName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.utf8.count <= 255 else { throw ProjectWorkspaceError.nameTooLong }
        guard DahliaProjectName.normalizedLeafName(name) == name else {
            throw ProjectWorkspaceError.invalidName
        }
        return name
    }
}

extension ProjectWorkspaceService {
    private func withNotifyingMutation<T>(_ operation: () throws -> T) throws -> T {
        let result = try withMutationLock(operation)
        DahliaWorkspaceChangeNotification.post(vaultID: vault.id)
        return result
    }

    private func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try DahliaVaultMutationLock.withLock(
                vaultURL: vault.url,
                vaultID: vault.id,
                operation: operation
            )
        } catch is DahliaVaultMutationLockError {
            throw ProjectWorkspaceError.vaultBusy
        }
    }

    private func ensureProjectDoesNotExist(name: String, excludingProjectId: UUID?) throws {
        let projects = try repository.fetchAllProjects(vaultId: vault.id)
        if projects.contains(where: {
            $0.id != excludingProjectId && ProjectRecord.pathKey($0.name) == ProjectRecord.pathKey(name)
        }) {
            throw ProjectWorkspaceError.projectAlreadyExists(name)
        }
    }

    private func projectURL(name: String) -> URL {
        vault.url.appending(path: name, directoryHint: .isDirectory)
    }

    private func makeMeetingMovePlan(ids: Set<UUID>, toProjectId: UUID?) throws -> MeetingMovePlan {
        guard !ids.isEmpty else {
            return MeetingMovePlan(meetingIds: [], relocations: [], vaultExportUpdates: [])
        }

        let candidates = try repository.fetchMeetingMoveCandidates(ids: ids, vaultId: vault.id)
            .filter { $0.projectId != toProjectId }
        guard !candidates.isEmpty else {
            return MeetingMovePlan(meetingIds: [], relocations: [], vaultExportUpdates: [])
        }
        let destinationDirectory = try summaryDestinationDirectory(toProjectId: toProjectId)
        let meetingIds = Set(candidates.map(\.meetingId))
        let externalSummaryPaths = try repository.externalVaultSummaryPaths(
            movingMeetingIds: meetingIds,
            vaultId: vault.id
        )
        let externallyReferencedSources = try Set(externalSummaryPaths.compactMap { relativePath
                -> DahliaWorkspaceFileIdentity? in
            guard let url = try summaryFileResolver(relativePath, vault.url) else { return nil }
            return DahliaWorkspaceFileIdentity.resolve(url, fileManager: fileManager)
        })
        var relocations: [SummaryRelocation] = []
        var updates: [MeetingRepository.MeetingVaultExportUpdate] = []
        var destinationPaths: Set<String> = []
        var destinationBySource: [DahliaWorkspaceFileIdentity: URL] = [:]

        for candidate in candidates where candidate.hasVaultExport {
            guard let sourceURL = try summaryFileResolver(candidate.vaultRelativePath, vault.url) else {
                updates.append(.init(meetingId: candidate.meetingId, relativePath: nil))
                continue
            }
            guard isInsideVaultAfterResolvingSymlinks(sourceURL),
                  pathContainsNoSymlinks(sourceURL) else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }

            try validateOutputDirectory(destinationDirectory)
            let destinationURL = destinationDirectory
                .appending(path: sourceURL.lastPathComponent, directoryHint: .notDirectory)
                .standardizedFileURL
            let standardizedSourceURL = sourceURL.standardizedFileURL
            guard let relativePath = VaultSummaryFileLocator.relativePath(
                for: destinationURL,
                vaultURL: vault.url
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
            vaultExportUpdates: updates
        )
    }

    private func summaryDestinationDirectory(toProjectId: UUID?) throws -> URL {
        let destinationDirectory: URL
        if let toProjectId {
            guard let destination = try repository.fetchProject(id: toProjectId),
                  destination.vaultId == vault.id
            else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
            destinationDirectory = projectURL(name: destination.name)
        } else {
            destinationDirectory = vault.url
        }
        return destinationDirectory
    }

    private func projectSummaryMovePlan(
        oldPrefix: String,
        newPrefix: String
    ) throws -> ProjectSummaryMovePlan {
        let meetingIds = try repository.meetingIds(projectHierarchy: oldPrefix, vaultId: vault.id)
        guard !meetingIds.isEmpty else {
            return ProjectSummaryMovePlan(relocations: [], vaultExportUpdates: [])
        }
        let candidates = try repository.fetchMeetingMoveCandidates(ids: meetingIds, vaultId: vault.id)
        let projects = try repository.fetchAllProjects(vaultId: vault.id)
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        let protectedIdentities = try protectedProjectSummaryIdentities(
            candidates: candidates,
            projectPaths: projectPaths,
            meetingIds: meetingIds
        )

        var relocations: [SummaryRelocation] = []
        var updates: [MeetingRepository.MeetingVaultExportUpdate] = []
        var destinations: Set<String> = []
        var destinationBySource: [DahliaWorkspaceFileIdentity: URL] = [:]
        for candidate in candidates where candidate.hasVaultExport {
            guard let projectId = candidate.projectId,
                  let oldProjectPath = projectPaths[projectId] else { continue }
            let newProjectPath = oldProjectPath == oldPrefix
                ? newPrefix
                : newPrefix + oldProjectPath.dropFirst(oldPrefix.count)
            guard let storedPath = candidate.vaultRelativePath else {
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
            guard let resolvedSourceURL = try summaryFileResolver(storedPath, vault.url) else {
                updates.append(.init(meetingId: candidate.meetingId, relativePath: nil))
                continue
            }
            guard isInsideVaultAfterResolvingSymlinks(resolvedSourceURL),
                  pathContainsNoSymlinks(resolvedSourceURL) else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
            let destinationURL = vault.url
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
            vaultExportUpdates: updates
        )
    }

    private func protectedProjectSummaryIdentities(
        candidates: [MeetingRepository.MeetingMoveCandidate],
        projectPaths: [UUID: String],
        meetingIds: Set<UUID>
    ) throws -> Set<DahliaWorkspaceFileIdentity> {
        let externalPaths = try repository.externalVaultSummaryPaths(
            movingMeetingIds: meetingIds,
            vaultId: vault.id
        )
        let externalIdentities = try Set(externalPaths.compactMap {
            try summaryFileResolver($0, vault.url).map {
                DahliaWorkspaceFileIdentity.resolve($0, fileManager: fileManager)
            }
        })
        let retainedIdentities: Set<DahliaWorkspaceFileIdentity> = try Set(candidates.compactMap { candidate in
            guard candidate.hasVaultExport,
                  let projectId = candidate.projectId,
                  let projectPath = projectPaths[projectId],
                  let storedPath = candidate.vaultRelativePath,
                  !storedPath.hasPrefix(projectPath + "/"),
                  let sourceURL = try summaryFileResolver(storedPath, vault.url)
            else {
                return nil
            }
            return DahliaWorkspaceFileIdentity.resolve(sourceURL, fileManager: fileManager)
        })
        return externalIdentities.union(retainedIdentities)
    }

    private func validateOutputDirectory(_ directory: URL) throws {
        let root = vault.url.standardizedFileURL
        let candidate = directory.standardizedFileURL
        let rootComponents = root.pathComponents
        guard candidate.pathComponents.starts(with: rootComponents) else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }

        var current = root
        for component in candidate.pathComponents.dropFirst(rootComponents.count) {
            current.append(path: component, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: current.path) else {
                guard isInsideVaultAfterResolvingSymlinks(current) else {
                    throw ProjectWorkspaceError.invalidMoveDestination
                }
                return
            }
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  isInsideVaultAfterResolvingSymlinks(current) else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
        }
        guard isDirectoryInsideVault(candidate) else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }
    }

    private func destinationConflicts(
        _ destination: URL,
        sourceIdentity: DahliaWorkspaceFileIdentity
    ) throws -> Bool {
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

    private func isDirectoryInsideVault(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && isInsideVaultAfterResolvingSymlinks(url)
            && pathContainsNoSymlinks(url)
    }

    private func isInsideVaultAfterResolvingSymlinks(_ url: URL) -> Bool {
        let vaultPath = vault.url.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"
        return candidatePath == vaultPath || candidatePath.hasPrefix(prefix)
    }

    private func pathContainsNoSymlinks(_ url: URL) -> Bool {
        let root = vault.url.standardizedFileURL
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

    static func resolveSummaryFile(storedRelativePath: String?, vaultURL: URL) throws -> URL? {
        guard let storedRelativePath,
              let fileURL = VaultSummaryFileLocator.fileURL(for: storedRelativePath, vaultURL: vaultURL),
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
    private func performSummaryRelocations(
        _ relocations: [SummaryRelocation],
        operation: () throws -> Void
    ) throws {
        let createdDirectories = try createOutputDirectories(for: relocations)
        var completed: [SummaryRelocation] = []
        do {
            for relocation in relocations {
                try fileManager.moveItem(at: relocation.sourceURL, to: relocation.destinationURL)
                completed.append(relocation)
            }
            try operation()
        } catch let operationError {
            var rollbackError: (any Error)?
            for relocation in completed.reversed() {
                do {
                    try fileManager.moveItem(at: relocation.destinationURL, to: relocation.sourceURL)
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

    private func createOutputDirectories(for relocations: [SummaryRelocation]) throws -> [URL] {
        let directories = Set(relocations.map { $0.destinationURL.deletingLastPathComponent().standardizedFileURL })
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        var created: [URL] = []
        do {
            for directory in directories {
                try validateOutputDirectory(directory)
                let root = vault.url.standardizedFileURL
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

    private func removeNewEmptyDirectory(_ url: URL) throws {
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
