import DahliaRuntimeSupport
import Foundation
import GRDB

/// 要約関連ファイルを Workspace に書き出すサービス。
enum WorkspaceSummaryExportService {
    struct LockedSummaryExportRequest: Sendable {
        let workspaceURL: URL
        let workspaceID: UUID
        let meetingID: UUID
        let dbQueue: DatabaseQueue
        let document: SummaryDocument
        let summaryFileName: String
        let summaryMarkdown: String
        var isAlreadyPersisted = false
        var previousWorkspaceRelativePath: String?
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
        workspaceURL: URL,
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
            workspaceURL: workspaceURL,
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
        workspaceURL: URL,
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
            workspaceURL: workspaceURL,
            storedSummaryRelativePath: storedSummaryRelativePath,
            meetingId: meetingId,
            summaryFileName: summaryFileName
        )

        return try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask {
                try writeSummary(summaryFileURL, summaryMarkdown)
            }
            group.addTask {
                _ = try exportTranscript(workspaceURL, meetingId, projectName, createdAt, segments, recordingSessions)
                return nil
            }
            if !screenshots.isEmpty {
                group.addTask {
                    let resolved = try await ScreenshotContentProvider.shared.resolved(screenshots)
                    _ = try exportScreenshots(workspaceURL, resolved)
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
        workspaceURL: URL,
        meetingId: UUID,
        projectName: String,
        createdAt: Date,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline],
        screenshots: [MeetingScreenshotRecord]
    ) async throws {
        try await exportSupportingArtifacts(
            workspaceURL: workspaceURL,
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
        workspaceURL: URL,
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
                    workspaceURL,
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
                    _ = try exportScreenshots(workspaceURL, resolved)
                }
            }
            try await group.waitForAll()
        }
    }

    static func exportSummary(
        _ request: LockedSummaryExportRequest
    ) async throws -> LockedSummaryExportResult? {
        try await withWorkspaceMutationLock(
            workspaceURL: request.workspaceURL,
            workspaceID: request.workspaceID
        ) {
            let latest = try request.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: request.meetingID)
                let project = try meeting?.projectId.flatMap {
                    try ProjectRecord.fetchResolved(id: $0, in: db)
                }
                let storedPath = try SummaryExportRecord.fetchOne(
                    meetingId: request.meetingID,
                    type: .workspace,
                    in: db
                )?.workspaceRelativePath
                return (meeting, project, storedPath)
            }
            guard let meeting = latest.0,
                  meeting.workspaceId == request.workspaceID else {
                return nil
            }

            let repository = MeetingRepository(dbQueue: request.dbQueue)
            if request.isAlreadyPersisted {
                guard try request.dbQueue.read({ db in
                    try SummaryBodyRecord.fetchOne(db, key: request.meetingID)?.document == request.document.databaseJSONString()
                }) else { throw TextContentError.changed }
            } else {
                try repository.applyGeneratedSummary(
                    toMeetingId: request.meetingID,
                    document: request.document,
                    tags: request.document.tags
                )
            }
            let projectName = latest.1?.path ?? ""
            let projectURL = latest.1.map {
                request.workspaceURL.appending(path: $0.path, directoryHint: .isDirectory)
            }
            let fileURL = try resolveSummaryFileURL(
                projectURL: projectURL,
                workspaceURL: request.workspaceURL,
                storedSummaryRelativePath: latest.2 ?? request.previousWorkspaceRelativePath,
                meetingId: request.meetingID,
                summaryFileName: request.summaryFileName
            )
            _ = try writeSummaryFile(
                fileURL: fileURL,
                markdown: request.summaryMarkdown
            )
            if let relativePath = WorkspaceSummaryFileLocator.relativePath(
                for: fileURL,
                workspaceURL: request.workspaceURL
            ) {
                try repository.updateSummaryWorkspaceRelativePath(
                    forMeetingId: request.meetingID,
                    relativePath: relativePath
                )
            }
            return LockedSummaryExportResult(fileURL: fileURL, projectName: projectName)
        }
    }

    static func withWorkspaceMutationLock<T: Sendable>(
        workspaceURL: URL,
        workspaceID: UUID,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try DahliaWorkspaceMutationLock.withLock(
                workspaceURL: workspaceURL,
                workspaceID: workspaceID,
                operation: operation
            )
        }.value
    }

    static func resolveSummaryFileURL(
        projectURL: URL?,
        workspaceURL: URL,
        storedSummaryRelativePath: String?,
        meetingId: UUID,
        summaryFileName: String
    ) throws -> URL {
        if let existing = SummaryService.findSummaryFile(
            storedRelativePath: storedSummaryRelativePath,
            workspaceURL: workspaceURL
        ) {
            try validateSummaryFile(existing, workspaceURL: workspaceURL)
            return existing
        }

        let directoryURL = projectURL ?? workspaceURL
        try prepareOutputDirectory(directoryURL, workspaceURL: workspaceURL)
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

    private static func prepareOutputDirectory(_ directoryURL: URL, workspaceURL: URL) throws {
        let fileManager = FileManager.default
        let root = workspaceURL.standardizedFileURL
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
                      isInsideWorkspace(current, workspaceURL: root) else {
                    throw ProjectWorkspaceError.invalidSummaryOutputDestination
                }
            } else {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }

    private static func validateSummaryFile(_ fileURL: URL, workspaceURL: URL) throws {
        let root = workspaceURL.standardizedFileURL
        let file = fileURL.standardizedFileURL
        let rootComponents = root.pathComponents
        guard file.pathComponents.starts(with: rootComponents),
              isInsideWorkspace(file, workspaceURL: root) else {
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

    private static func isInsideWorkspace(_ url: URL, workspaceURL: URL) -> Bool {
        let rootPath = workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
    }
}
