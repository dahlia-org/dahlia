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

    private struct MeetingMovePlan {
        let meetingIds: Set<UUID>
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
                guard existing.missingOnDisk else { return (existing, false) }

                let matchingURL = try fileManager.contentsOfDirectory(
                    at: vault.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                ).first {
                    DahliaProjectName.siblingKey($0.lastPathComponent)
                        == DahliaProjectName.siblingKey(existing.leafName)
                }
                let createdURL: URL?
                if let matchingURL {
                    let values = try matchingURL.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                    ])
                    guard values.isDirectory == true,
                          values.isSymbolicLink != true else {
                        throw ProjectWorkspaceError.folderAlreadyExists(matchingURL.lastPathComponent)
                    }
                    createdURL = nil
                } else {
                    let projectURL = vault.url.appending(
                        path: existing.leafName,
                        directoryHint: .isDirectory
                    )
                    try fileManager.createDirectory(
                        at: projectURL,
                        withIntermediateDirectories: false
                    )
                    createdURL = projectURL
                }
                do {
                    try repository.upsertProjects(
                        names: [matchingURL?.lastPathComponent ?? existing.leafName],
                        vaultId: vault.id
                    )
                    return try (repository.fetchProject(id: existing.id) ?? existing, true)
                } catch {
                    if let createdURL {
                        try? removeNewEmptyDirectory(createdURL)
                    }
                    throw error
                }
            }

            return try (
                createProjectUnlocked(leafName: leafName, parentProjectId: nil),
                true
            )
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
            guard !project.missingOnDisk else { throw ProjectWorkspaceError.parentFolderMissing }
            return project
        }
        if parent != nil, projectType != nil {
            throw ProjectWorkspaceError.typeOwnedByRoot
        }
        let name = parent.map { "\($0.name)/\(leafName)" } ?? leafName
        try ensureProjectDoesNotExist(name: name, excludingProjectId: nil)

        let parentURL = parent.map { projectURL(name: $0.name) } ?? vault.url
        guard isDirectoryInsideVault(parentURL) else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }
        try ensureFolderDoesNotExist(named: leafName, in: parentURL, excluding: nil)
        let url = parentURL.appending(path: leafName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)

        do {
            return try repository.createProject(
                vaultId: vault.id,
                parentProjectId: parentProjectId,
                leafName: leafName,
                description: description,
                projectType: projectType
            )
        } catch let operationError {
            do {
                try removeNewEmptyDirectory(url)
            } catch let rollbackError {
                throw ProjectWorkspaceError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw operationError
        }
    }

    func renameProject(id: UUID, newLeafName: String) throws -> ProjectRecord {
        try withNotifyingMutation {
            try renameProjectUnlocked(id: id, newLeafName: newLeafName)
        }
    }

    private func renameProjectUnlocked(id: UUID, newLeafName: String) throws -> ProjectRecord {
        guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
            throw ProjectWorkspaceError.projectNotFound
        }
        guard !project.missingOnDisk else { throw ProjectWorkspaceError.folderMissing }

        let newLeafName = try Self.validatedLeafName(newLeafName)
        let oldLeafName = project.name.split(separator: "/").last.map(String.init) ?? project.name
        guard newLeafName != oldLeafName else { return project }

        let parentName = project.name.split(separator: "/").dropLast().joined(separator: "/")
        let newName = parentName.isEmpty ? newLeafName : "\(parentName)/\(newLeafName)"
        try ensureProjectDoesNotExist(name: newName, excludingProjectId: id)

        let oldURL = projectURL(name: project.name)
        let newURL = projectURL(name: newName)
        guard isDirectoryInsideVault(oldURL) else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }
        try ensureFolderDoesNotExist(
            named: newLeafName,
            in: oldURL.deletingLastPathComponent(),
            excluding: oldURL
        )
        try moveProjectFolder(from: oldURL, to: newURL)

        let renamed: ProjectRecord
        do {
            renamed = try repository.renameProjectsByPrefix(
                oldPrefix: project.name,
                newPrefix: newName,
                vaultId: vault.id
            )
        } catch {
            do {
                try moveProjectFolder(from: newURL, to: oldURL)
            } catch let rollbackError {
                throw ProjectWorkspaceError.rollbackFailed(
                    operation: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }

        return renamed
    }

    func reparentProject(id: UUID, parentProjectId: UUID?) throws -> ProjectRecord {
        try withNotifyingMutation {
            try reparentProjectUnlocked(id: id, parentProjectId: parentProjectId)
        }
    }

    private func reparentProjectUnlocked(id: UUID, parentProjectId: UUID?) throws -> ProjectRecord {
        guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
            throw ProjectWorkspaceError.projectNotFound
        }
        guard !project.missingOnDisk else { throw ProjectWorkspaceError.folderMissing }
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
            guard !parent.missingOnDisk else { throw ProjectWorkspaceError.parentFolderMissing }
            return parent
        }
        let newName = parent.map { "\($0.name)/\(project.leafName)" } ?? project.leafName
        try ensureProjectDoesNotExist(name: newName, excludingProjectId: id)

        let oldURL = projectURL(name: project.name)
        let destinationParentURL = parent.map { projectURL(name: $0.name) } ?? vault.url
        guard isDirectoryInsideVault(oldURL) else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }
        guard isDirectoryInsideVault(destinationParentURL) else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }
        try ensureFolderDoesNotExist(named: project.leafName, in: destinationParentURL, excluding: oldURL)
        let newURL = destinationParentURL.appending(path: project.leafName, directoryHint: .isDirectory)
        try moveProjectFolder(from: oldURL, to: newURL)

        let moved: ProjectRecord
        do {
            moved = try repository.renameProjectsByPrefix(
                oldPrefix: project.name,
                newPrefix: newName,
                vaultId: vault.id
            )
        } catch {
            do {
                try moveProjectFolder(from: newURL, to: oldURL)
            } catch let rollbackError {
                throw ProjectWorkspaceError.rollbackFailed(
                    operation: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }

        return moved
    }

    func updateRootProjectType(id: UUID, projectType: ProjectType) throws -> ProjectRecord {
        try withNotifyingMutation {
            guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
                throw ProjectWorkspaceError.projectNotFound
            }
            return try repository.updateRootProjectType(
                id: id,
                vaultId: vault.id,
                projectType: projectType
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
                description: description
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

    func deleteProjectHierarchy(id: UUID, meetingDisposition: ProjectMeetingDisposition) async throws {
        try withNotifyingMutation {
            try deleteProjectHierarchyUnlocked(id: id, meetingDisposition: meetingDisposition)
        }
    }

    private func deleteProjectHierarchyUnlocked(
        id: UUID,
        meetingDisposition: ProjectMeetingDisposition
    ) throws {
        guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
            throw ProjectWorkspaceError.projectNotFound
        }

        let movePlan: MeetingMovePlan?
        if case let .move(destinationId) = meetingDisposition {
            guard let destination = try repository.fetchProject(id: destinationId),
                  destination.vaultId == vault.id,
                  !destination.missingOnDisk,
                  !ProjectRecord.belongsToHierarchy(destination.name, prefix: project.name)
            else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
            let hierarchyMeetingIds = try repository.meetingIds(projectHierarchy: project.name, vaultId: vault.id)
            movePlan = try makeMeetingMovePlan(ids: hierarchyMeetingIds, toProjectId: destinationId)
        } else {
            movePlan = nil
        }

        let relocations = movePlan?.relocations ?? []
        try performSummaryRelocations(relocations) {
            let originalURL = projectURL(name: project.name)
            if fileManager.fileExists(atPath: originalURL.path),
               !isDirectoryInsideVault(originalURL) {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
            let trashedURL: URL? = if fileManager.fileExists(atPath: originalURL.path) {
                try trashHandler(originalURL)
            } else {
                nil
            }

            do {
                try repository.deleteProjectHierarchy(
                    name: project.name,
                    vaultId: vault.id,
                    meetingDisposition: meetingDisposition,
                    vaultExportUpdates: movePlan?.vaultExportUpdates ?? [],
                    managedAudioRootURL: managedAudioRootURL
                )
            } catch {
                guard let trashedURL else { throw error }
                do {
                    try fileManager.moveItem(at: trashedURL, to: originalURL)
                } catch let rollbackError {
                    throw ProjectWorkspaceError.rollbackFailed(
                        operation: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw error
            }
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

    private func ensureFolderDoesNotExist(named name: String, in parentURL: URL, excluding excludedURL: URL?) throws {
        let excludedURL = excludedURL?.standardizedFileURL
        let urls = try fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if urls.contains(where: {
            $0.standardizedFileURL != excludedURL
                && DahliaProjectName.siblingKey($0.lastPathComponent) == DahliaProjectName.siblingKey(name)
        }) {
            throw ProjectWorkspaceError.folderAlreadyExists(name)
        }
    }

    private func projectURL(name: String) -> URL {
        vault.url.appending(path: name, directoryHint: .isDirectory)
    }

    private func makeMeetingMovePlan(ids: Set<UUID>, toProjectId: UUID?) throws -> MeetingMovePlan {
        guard !ids.isEmpty else {
            return MeetingMovePlan(meetingIds: [], relocations: [], vaultExportUpdates: [])
        }

        let destinationDirectory = try summaryDestinationDirectory(toProjectId: toProjectId)
        let candidates = try repository.fetchMeetingMoveCandidates(ids: ids, vaultId: vault.id)
            .filter { $0.projectId != toProjectId }
        guard !candidates.isEmpty else {
            return MeetingMovePlan(meetingIds: [], relocations: [], vaultExportUpdates: [])
        }
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
        let existingDestinationKeys = try normalizedSiblingKeys(in: destinationDirectory)
        var relocations: [SummaryRelocation] = []
        var updates: [MeetingRepository.MeetingVaultExportUpdate] = []
        var destinationPaths: Set<String> = []
        var destinationBySource: [DahliaWorkspaceFileIdentity: URL] = [:]

        for candidate in candidates where candidate.hasVaultExport {
            guard let sourceURL = try summaryFileResolver(candidate.vaultRelativePath, vault.url) else {
                updates.append(.init(meetingId: candidate.meetingId, relativePath: nil))
                continue
            }
            guard isInsideVaultAfterResolvingSymlinks(sourceURL) else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }

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
            let destinationLeafKey = DahliaProjectName.siblingKey(destinationURL.lastPathComponent)
            if !destinationPaths.insert(destinationKey).inserted
                || existingDestinationKeys.contains(destinationLeafKey) {
                throw ProjectWorkspaceError.summaryFileAlreadyExists(destinationURL.lastPathComponent)
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
                  destination.vaultId == vault.id,
                  !destination.missingOnDisk
            else {
                throw ProjectWorkspaceError.invalidMoveDestination
            }
            destinationDirectory = projectURL(name: destination.name)
        } else {
            destinationDirectory = vault.url
        }
        guard isDirectoryInsideVault(destinationDirectory) else {
            throw ProjectWorkspaceError.invalidMoveDestination
        }
        return destinationDirectory
    }

    private func normalizedSiblingKeys(in directory: URL) throws -> Set<String> {
        try Set(
            fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).map { DahliaProjectName.siblingKey($0.lastPathComponent) }
        )
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

    /// File system and SQLite operations cannot share a transaction. Runtime failures are compensated here;
    /// process termination follows the same existing limitation as project folder rename and deletion.
    private func performSummaryRelocations(
        _ relocations: [SummaryRelocation],
        operation: () throws -> Void
    ) throws {
        var completed: [SummaryRelocation] = []
        do {
            for relocation in relocations {
                try fileManager.moveItem(at: relocation.sourceURL, to: relocation.destinationURL)
                completed.append(relocation)
            }
            try operation()
        } catch {
            var rollbackError: (any Error)?
            for relocation in completed.reversed() {
                do {
                    try fileManager.moveItem(at: relocation.destinationURL, to: relocation.sourceURL)
                } catch {
                    rollbackError = rollbackError ?? error
                }
            }
            if let rollbackError {
                throw ProjectWorkspaceError.rollbackFailed(
                    operation: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    private func moveProjectFolder(from sourceURL: URL, to destinationURL: URL) throws {
        if DahliaProjectName.siblingKey(sourceURL.lastPathComponent)
            == DahliaProjectName.siblingKey(destinationURL.lastPathComponent) {
            let temporaryURL = sourceURL.deletingLastPathComponent()
                .appending(path: ".dahlia-rename-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.moveItem(at: sourceURL, to: temporaryURL)
            do {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            } catch let operationError {
                do {
                    try fileManager.moveItem(at: temporaryURL, to: sourceURL)
                } catch let rollbackError {
                    throw ProjectWorkspaceError.rollbackFailed(
                        operation: operationError.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw operationError
            }
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
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
