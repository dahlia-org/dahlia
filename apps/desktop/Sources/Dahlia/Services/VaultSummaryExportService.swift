import DahliaRuntimeSupport
import Foundation
import GRDB

/// 要約関連ファイルを Vault に書き出すサービス。
enum VaultSummaryExportService {
    struct LockedSummaryExportRequest: Sendable {
        let vaultURL: URL
        let vaultID: UUID
        let meetingID: UUID
        let dbQueue: DatabaseQueue
        let document: SummaryDocument
        let summaryFileName: String
        let summaryMarkdown: String
    }

    struct LockedSummaryExportResult: Sendable {
        let fileURL: URL
        let projectName: String
    }

    typealias TranscriptExporter = @Sendable (URL, UUID, String, Date, [TranscriptSegment], [RecordingSessionTimeline]) throws -> String
    typealias ScreenshotExporter = @Sendable (URL, [MeetingScreenshotRecord]) throws -> [String]
    typealias SummaryWriter = @Sendable (URL, String) throws -> URL

    // The public export boundary mirrors the complete summary bundle payload.
    // swiftlint:disable:next function_parameter_count
    static func exportSummaryBundle(
        projectURL: URL?,
        vaultURL: URL,
        storedSummaryRelativePath: String? = nil,
        meetingId: UUID,
        createdAt: Date,
        projectName: String,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline] = [],
        screenshots: [MeetingScreenshotRecord],
        summaryFileName: String,
        summaryMarkdown: String
    ) async throws -> URL {
        try await exportSummaryBundle(
            projectURL: projectURL,
            vaultURL: vaultURL,
            storedSummaryRelativePath: storedSummaryRelativePath,
            meetingId: meetingId,
            createdAt: createdAt,
            projectName: projectName,
            segments: segments,
            recordingSessions: recordingSessions,
            screenshots: screenshots,
            summaryFileName: summaryFileName,
            summaryMarkdown: summaryMarkdown,
            exportTranscript: TranscriptExportService.exportTranscript,
            exportScreenshots: ScreenshotExportService.exportScreenshots,
            writeSummary: writeSummaryFile
        )
    }

    // Test seams add exporter closures to the same complete payload.
    // swiftlint:disable:next function_parameter_count
    static func exportSummaryBundle(
        projectURL: URL?,
        vaultURL: URL,
        storedSummaryRelativePath: String? = nil,
        meetingId: UUID,
        createdAt: Date,
        projectName: String,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline] = [],
        screenshots: [MeetingScreenshotRecord],
        summaryFileName: String,
        summaryMarkdown: String,
        exportTranscript: @escaping TranscriptExporter,
        exportScreenshots: @escaping ScreenshotExporter,
        writeSummary: @escaping SummaryWriter
    ) async throws -> URL {
        let summaryFileURL = try resolveSummaryFileURL(
            projectURL: projectURL,
            vaultURL: vaultURL,
            storedSummaryRelativePath: storedSummaryRelativePath,
            meetingId: meetingId,
            summaryFileName: summaryFileName
        )

        return try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask {
                try writeSummary(summaryFileURL, summaryMarkdown)
            }
            group.addTask {
                _ = try exportTranscript(vaultURL, meetingId, projectName, createdAt, segments, recordingSessions)
                return nil
            }
            if !screenshots.isEmpty {
                group.addTask {
                    let resolved = try await ScreenshotContentProvider.shared.resolved(screenshots)
                    _ = try exportScreenshots(vaultURL, resolved)
                    return nil
                }
            }

            var exportedSummaryURL: URL?
            for try await url in group {
                if let url {
                    exportedSummaryURL = url
                }
            }

            return exportedSummaryURL ?? summaryFileURL
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func exportSupportingArtifacts(
        vaultURL: URL,
        meetingId: UUID,
        projectName: String,
        createdAt: Date,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline],
        screenshots: [MeetingScreenshotRecord]
    ) async throws {
        try await exportSupportingArtifacts(
            vaultURL: vaultURL,
            meetingId: meetingId,
            projectName: projectName,
            createdAt: createdAt,
            segments: segments,
            recordingSessions: recordingSessions,
            screenshots: screenshots,
            exportTranscript: TranscriptExportService.exportTranscript,
            exportScreenshots: ScreenshotExportService.exportScreenshots
        )
    }

    // Test seams add exporter closures to the same supporting-artifact payload.
    // swiftlint:disable:next function_parameter_count
    static func exportSupportingArtifacts(
        vaultURL: URL,
        meetingId: UUID,
        projectName: String,
        createdAt: Date,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline],
        screenshots: [MeetingScreenshotRecord],
        exportTranscript: @escaping TranscriptExporter,
        exportScreenshots: @escaping ScreenshotExporter
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try exportTranscript(
                    vaultURL,
                    meetingId,
                    projectName,
                    createdAt,
                    segments,
                    recordingSessions
                )
            }
            if !screenshots.isEmpty {
                group.addTask {
                    let resolved = try await ScreenshotContentProvider.shared.resolved(screenshots)
                    _ = try exportScreenshots(vaultURL, resolved)
                }
            }
            try await group.waitForAll()
        }
    }

    static func exportSummary(
        _ request: LockedSummaryExportRequest
    ) async throws -> LockedSummaryExportResult? {
        try await withVaultMutationLock(
            vaultURL: request.vaultURL,
            vaultID: request.vaultID
        ) {
            let latest = try request.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: request.meetingID)
                let project = try meeting?.projectId.flatMap {
                    try ProjectRecord.fetchResolved(id: $0, in: db)
                }
                let storedPath = try SummaryExportRecord.fetchOne(
                    meetingId: request.meetingID,
                    type: .vault,
                    in: db
                )?.vaultRelativePath
                return (meeting, project, storedPath)
            }
            guard let meeting = latest.0,
                  meeting.vaultId == request.vaultID else {
                return nil
            }

            let repository = MeetingRepository(dbQueue: request.dbQueue)
            try repository.applyGeneratedSummary(
                toMeetingId: request.meetingID,
                document: request.document,
                tags: request.document.tags
            )
            let projectName = latest.1?.path ?? ""
            let projectURL = latest.1.map {
                request.vaultURL.appending(path: $0.path, directoryHint: .isDirectory)
            }
            let fileURL = try resolveSummaryFileURL(
                projectURL: projectURL,
                vaultURL: request.vaultURL,
                storedSummaryRelativePath: latest.2,
                meetingId: request.meetingID,
                summaryFileName: request.summaryFileName
            )
            _ = try writeSummaryFile(
                fileURL: fileURL,
                markdown: request.summaryMarkdown
            )
            if let relativePath = VaultSummaryFileLocator.relativePath(
                for: fileURL,
                vaultURL: request.vaultURL
            ) {
                try repository.updateSummaryVaultRelativePath(
                    forMeetingId: request.meetingID,
                    relativePath: relativePath
                )
            }
            return LockedSummaryExportResult(fileURL: fileURL, projectName: projectName)
        }
    }

    static func withVaultMutationLock<T: Sendable>(
        vaultURL: URL,
        vaultID: UUID,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try DahliaVaultMutationLock.withLock(
                vaultURL: vaultURL,
                vaultID: vaultID,
                operation: operation
            )
        }.value
    }

    static func resolveSummaryFileURL(
        projectURL: URL?,
        vaultURL: URL,
        storedSummaryRelativePath: String?,
        meetingId: UUID,
        summaryFileName: String
    ) throws -> URL {
        if let existing = SummaryService.findSummaryFile(
            storedRelativePath: storedSummaryRelativePath,
            vaultURL: vaultURL
        ) {
            try validateSummaryFile(existing, vaultURL: vaultURL)
            return existing
        }

        let directoryURL = projectURL ?? vaultURL
        try prepareOutputDirectory(directoryURL, vaultURL: vaultURL)
        let preferredURL = directoryURL.appendingPathComponent(summaryFileName)
        guard FileManager.default.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let fileExtension = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent
        let disambiguatedName = fileExtension.isEmpty
            ? "\(stem)-\(meetingId.uuidString)"
            : "\(stem)-\(meetingId.uuidString).\(fileExtension)"
        let disambiguatedURL = directoryURL.appendingPathComponent(disambiguatedName)
        guard !FileManager.default.fileExists(atPath: disambiguatedURL.path) else {
            throw ProjectWorkspaceError.summaryFileAlreadyExists(disambiguatedURL.lastPathComponent)
        }
        return disambiguatedURL
    }

    static func writeSummaryFile(fileURL: URL, markdown: String) throws -> URL {
        try Data(markdown.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func prepareOutputDirectory(_ directoryURL: URL, vaultURL: URL) throws {
        let fileManager = FileManager.default
        let root = vaultURL.standardizedFileURL
        let destination = directoryURL.standardizedFileURL
        let rootComponents = root.pathComponents
        guard destination.pathComponents.starts(with: rootComponents),
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ProjectWorkspaceError.invalidSummaryOutputDestination
        }

        var current = root
        for component in destination.pathComponents.dropFirst(rootComponents.count) {
            current.append(path: component, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true,
                      values.isSymbolicLink != true,
                      isInsideVault(current, vaultURL: root) else {
                    throw ProjectWorkspaceError.invalidSummaryOutputDestination
                }
            } else {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }

    private static func validateSummaryFile(_ fileURL: URL, vaultURL: URL) throws {
        let root = vaultURL.standardizedFileURL
        let file = fileURL.standardizedFileURL
        let rootComponents = root.pathComponents
        guard file.pathComponents.starts(with: rootComponents),
              isInsideVault(file, vaultURL: root) else {
            throw ProjectWorkspaceError.invalidSummaryOutputDestination
        }

        var current = root
        for component in file.pathComponents.dropFirst(rootComponents.count) {
            current.append(path: component)
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ProjectWorkspaceError.invalidSummaryOutputDestination
            }
        }
    }

    private static func isInsideVault(_ url: URL, vaultURL: URL) -> Bool {
        let rootPath = vaultURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
    }
}
