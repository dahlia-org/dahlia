import DahliaRuntimeSupport
import Foundation

/// スクリーンショットを Vault の `_dahlia/screenshots/` フォルダに書き出すサービス。
enum ScreenshotExportService {
    static func screenshotsDirectoryURL(in vaultURL: URL) -> URL {
        vaultURL
            .appendingPathComponent("_dahlia", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    static func filename(for screenshot: MeetingScreenshotRecord) -> String {
        "\(screenshot.id.uuidString).\(fileExtension(for: screenshot))"
    }

    /// スクリーンショットを `<vault>/_dahlia/screenshots/<screenshotId>.<ext>` に書き出す。
    /// DB の `imageData` をそのまま書き出す。
    /// - Returns: vault 相対パスの配列
    static func exportScreenshots(
        vaultURL: URL,
        screenshots: [MeetingScreenshotRecord]
    ) throws -> [String] {
        guard !screenshots.isEmpty else { return [] }

        let dir = screenshotsDirectoryURL(in: vaultURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var relativePaths: [String] = []

        for screenshot in screenshots {
            let filename = filename(for: screenshot)
            let relativePath = "_dahlia/screenshots/\(filename)"
            let fileURL = vaultURL.appendingPathComponent(relativePath)
            try screenshot.imageData.write(to: fileURL, options: .atomic)
            relativePaths.append(relativePath)
        }

        return relativePaths
    }

    static func deleteExportedScreenshots(
        vaultURL: URL,
        screenshots: [MeetingScreenshotRecord]
    ) throws {
        let directoryURL = screenshotsDirectoryURL(in: vaultURL)
        for screenshot in screenshots {
            let fileURL = directoryURL.appending(path: filename(for: screenshot))
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func fileExtension(for screenshot: MeetingScreenshotRecord) -> String {
        ImageEncoder.fileExtension(mimeType: screenshot.mimeType, data: screenshot.imageData)
    }
}
