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

    func createProject(leafName: String, parentProjectId: UUID?) throws -> ProjectRecord {
        let leafName = try Self.validatedLeafName(leafName)
        let parent = try parentProjectId.map { id in
            guard let project = try repository.fetchProject(id: id), project.vaultId == vault.id else {
                throw ProjectWorkspaceError.projectNotFound
            }
            guard !project.missingOnDisk else { throw ProjectWorkspaceError.parentFolderMissing }
            return project
        }
        let name = parent.map { "\($0.name)/\(leafName)" } ?? leafName
        try ensureProjectDoesNotExist(name: name, excludingProjectId: nil)

        let parentURL = parent.map { projectURL(name: $0.name) } ?? vault.url
        try ensureFolderDoesNotExist(named: leafName, in: parentURL, excluding: nil)
        let url = parentURL.appending(path: leafName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)

        do {
            return try repository.fetchOrCreateProject(name: name, vaultId: vault.id)
        } catch {
            removeNewEmptyDirectoryIfPossible(url)
            throw error
        }
    }

    func renameProject(id: UUID, newLeafName: String) throws -> ProjectRecord {
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
        try ensureFolderDoesNotExist(
            named: newLeafName,
            in: oldURL.deletingLastPathComponent(),
            excluding: oldURL
        )
        try moveProjectFolder(from: oldURL, to: newURL)

        do {
            try repository.renameProjectsByPrefix(oldPrefix: project.name, newPrefix: newName, vaultId: vault.id)
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

        guard let renamed = try repository.fetchProject(id: id) else {
            throw ProjectWorkspaceError.projectNotFound
        }
        return renamed
    }

    func moveMeeting(id: UUID, toProjectId: UUID?) throws {
        try moveMeetings(ids: [id], toProjectId: toProjectId)
    }

    func moveMeetings(ids: Set<UUID>, toProjectId: UUID?) throws {
        let plan = try makeMeetingMovePlan(ids: ids, toProjectId: toProjectId)
        guard !plan.meetingIds.isEmpty else { return }

        try performSummaryRelocations(plan.relocations) {
            try repository.commitMeetingMove(
                ids: plan.meetingIds,
                toProjectId: toProjectId,
                vaultId: vault.id,
                vaultExportUpdates: plan.vaultExportUpdates
            )
        }
    }

    func deleteProjectHierarchy(id: UUID, meetingDisposition: ProjectMeetingDisposition) async throws {
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

        if meetingDisposition == .deleteMeetings {
            try await repository.prepareSegmentedAudioForProjectDeletion(
                name: project.name,
                vaultId: vault.id,
                managedRootURL: managedAudioRootURL
            )
        }

        let relocations = movePlan?.relocations ?? []
        try performSummaryRelocations(relocations) {
            let originalURL = projectURL(name: project.name)
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
                    vaultExportUpdates: movePlan?.vaultExportUpdates ?? []
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
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.hasPrefix("."),
              !name.hasPrefix("_"),
              !name.contains("/"),
              !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw ProjectWorkspaceError.invalidName
        }
        guard name.utf8.count <= 255 else { throw ProjectWorkspaceError.nameTooLong }
        return name
    }
}

extension ProjectWorkspaceService {
    private func ensureProjectDoesNotExist(name: String, excludingProjectId: UUID?) throws {
        let projects = try repository.fetchAllProjects(vaultId: vault.id)
        if projects.contains(where: {
            $0.id != excludingProjectId && $0.name.caseInsensitiveCompare(name) == .orderedSame
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
                && $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
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
        let meetingIds = Set(candidates.map(\.meetingId))
        let sharedSummaryPaths = try repository.sharedVaultSummaryPaths(
            relativePaths: Set(candidates.compactMap(\.vaultRelativePath)),
            vaultId: vault.id
        )
        var relocations: [SummaryRelocation] = []
        var updates: [MeetingRepository.MeetingVaultExportUpdate] = []
        var destinationPaths: Set<String> = []

        for candidate in candidates where candidate.hasVaultExport {
            guard let sourceURL = try summaryFileResolver(candidate.vaultRelativePath, vault.url),
                  isInsideVaultAfterResolvingSymlinks(sourceURL)
            else {
                updates.append(.init(meetingId: candidate.meetingId, relativePath: nil))
                continue
            }
            if let relativePath = candidate.vaultRelativePath, sharedSummaryPaths.contains(relativePath) {
                throw ProjectWorkspaceError.summaryFileShared(sourceURL.lastPathComponent)
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

            let destinationKey = destinationURL.path.lowercased()
            if !destinationPaths.insert(destinationKey).inserted || fileManager.fileExists(atPath: destinationURL.path) {
                throw ProjectWorkspaceError.summaryFileAlreadyExists(destinationURL.lastPathComponent)
            }
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

    private func isDirectoryInsideVault(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && isInsideVaultAfterResolvingSymlinks(url)
    }

    private func isInsideVaultAfterResolvingSymlinks(_ url: URL) -> Bool {
        let vaultPath = vault.url.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"
        return candidatePath == vaultPath || candidatePath.hasPrefix(prefix)
    }

    static func resolveSummaryFile(storedRelativePath: String?, vaultURL: URL) throws -> URL? {
        guard let storedRelativePath,
              let fileURL = VaultSummaryFileLocator.fileURL(for: storedRelativePath, vaultURL: vaultURL),
              fileURL.pathExtension.lowercased() == "md"
        else { return nil }

        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? fileURL : nil
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
        if sourceURL.lastPathComponent.caseInsensitiveCompare(destinationURL.lastPathComponent) == .orderedSame {
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

    private func removeNewEmptyDirectoryIfPossible(_ url: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path), contents.isEmpty else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func moveToTrash(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else { throw ProjectWorkspaceError.trashLocationUnavailable }
        return resultingURL as URL
    }
}
