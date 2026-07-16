import Foundation

/// 要約関連ファイルを Vault に書き出すサービス。
enum VaultSummaryExportService {
    typealias TranscriptExporter = @Sendable (URL, UUID, String, Date, [TranscriptSegment], [RecordingSessionTimeline]) throws -> String
    typealias ScreenshotExporter = @Sendable (URL, [MeetingScreenshotRecord]) throws -> [String]
    typealias SummaryWriter = @Sendable (URL, String) throws -> URL

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
                    _ = try exportScreenshots(vaultURL, screenshots)
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

    static func resolveSummaryFileURL(
        projectURL: URL?,
        vaultURL: URL,
        storedSummaryRelativePath: String?,
        summaryFileName: String
    ) throws -> URL {
        if let existing = SummaryService.findSummaryFile(
            storedRelativePath: storedSummaryRelativePath,
            vaultURL: vaultURL
        ) {
            return existing
        }

        let directoryURL = projectURL ?? vaultURL
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appendingPathComponent(summaryFileName)
    }

    static func writeSummaryFile(fileURL: URL, markdown: String) throws -> URL {
        try Data(markdown.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }
}
