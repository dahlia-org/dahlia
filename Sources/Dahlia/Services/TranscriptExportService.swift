import Foundation

/// 文字起こしテキストを Obsidian 互換の Markdown ファイルとして書き出すサービス。
enum TranscriptExportService {
    static func transcriptsDirectoryURL(in vaultURL: URL) -> URL {
        vaultURL
            .appendingPathComponent("_dahlia", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 文字起こしを `<vault>/_dahlia/transcripts/{meetingId}.md` に書き出す。
    /// ファイルが既に存在する場合は上書きする。
    /// - Returns: vault 相対パス（例: `_dahlia/transcripts/XXXXXXXX-....md`）
    static func exportTranscript(
        vaultURL: URL,
        meetingId: UUID,
        projectName: String,
        createdAt: Date,
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline] = []
    ) throws -> String {
        let transcriptsDir = transcriptsDirectoryURL(in: vaultURL)
        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)

        let dateString = dateFormatter.string(from: createdAt)

        let frontmatter = """
        ---
        project: "\(projectName)"
        date: \(dateString)
        ---
        """

        let body: String = segments.map { (segment: TranscriptSegment) -> String in
            let time = Formatters.elapsedHHmmss(
                at: segment.startTime,
                sessionId: segment.sessionId,
                sessions: recordingSessions,
                fallbackTimeBase: createdAt
            )
            return "###### \(time)\n\(segment.displayText)"
        }.joined(separator: "\n")

        let markdown: String = frontmatter + "\n" + body + "\n"

        let relativePath = "_dahlia/transcripts/\(meetingId.uuidString).md"
        let fileURL = vaultURL.appendingPathComponent(relativePath)
        try Data(markdown.utf8).write(to: fileURL, options: .atomic)

        return relativePath
    }
}
