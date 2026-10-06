import DahliaRuntimeSupport
import Foundation

/// 以前 Workspace の `_dahlia/screenshots/` に書き出したスクリーンショットを扱う。
/// 要約 Markdown はアプリ管理下の原本を参照するため、新たには書き出さない。
enum ScreenshotExportService {
    static func screenshotsDirectoryURL(in workspaceURL: URL) -> URL {
        workspaceURL
            .appendingPathComponent("_dahlia", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    static func filename(for screenshot: MeetingScreenshotRecord) -> String {
        "\(screenshot.id.uuidString).\(ImageEncoder.fileExtension(mimeType: screenshot.mimeType, data: screenshot.imageData ?? Data()))"
    }

    /// 削除したスクリーンショットの、以前書き出した複製を Workspace から取り除く。
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
