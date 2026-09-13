import DahliaRuntimeSupport
import Foundation

/// スクリーンショットを Workspace の `_dahlia/screenshots/` フォルダに書き出すサービス。
enum ScreenshotExportService {
    static func screenshotsDirectoryURL(in workspaceURL: URL) -> URL {
        workspaceURL
            .appendingPathComponent("_dahlia", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    static func filename(for screenshot: MeetingScreenshotRecord) -> String {
        SummaryScreenshotFilename.filename(
            id: screenshot.id,
            mimeType: screenshot.mimeType,
            imageData: screenshot.imageData ?? Data()
        )
    }

    /// スクリーンショットを `<workspace>/_dahlia/screenshots/<screenshotId>.<ext>` に書き出す。
    /// DB の `imageData` をそのまま書き出す。
    /// - Returns: workspace 相対パスの配列
    static func exportScreenshots(
        workspaceURL: URL,
        screenshots: [MeetingScreenshotRecord]
    ) throws -> [String] {
        guard !screenshots.isEmpty else { return [] }

        let dir = screenshotsDirectoryURL(in: workspaceURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var relativePaths: [String] = []

        for screenshot in screenshots {
            let filename = filename(for: screenshot)
            let relativePath = "_dahlia/screenshots/\(filename)"
            let fileURL = workspaceURL.appendingPathComponent(relativePath)
            guard let bytes = screenshot.imageData else { throw ScreenshotContentError.unavailable }
            try bytes.write(to: fileURL, options: .atomic)
            relativePaths.append(relativePath)
        }

        return relativePaths
    }

    static func deleteExportedScreenshots(
        workspaceURL: URL,
        screenshots: [MeetingScreenshotRecord]
    ) throws {
        let directoryURL = screenshotsDirectoryURL(in: workspaceURL)
        for screenshot in screenshots {
            let fileURL = directoryURL.appending(path: filename(for: screenshot))
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
