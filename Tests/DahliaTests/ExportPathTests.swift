import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

struct ExportPathTests {
    @Test
    func transcriptExportWritesIntoDahliaTranscriptsDirectory() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let meetingId = UUID()
        let relativePath = try TranscriptExportService.exportTranscript(
            vaultURL: vaultURL,
            meetingId: meetingId,
            projectName: "Test Project",
            createdAt: Date(timeIntervalSince1970: 0),
            segments: [
                TranscriptSegment(
                    startTime: Date(timeIntervalSince1970: 0),
                    text: "hello"
                )
            ]
        )

        #expect(relativePath == "_dahlia/transcripts/\(meetingId.uuidString).md")
        #expect(FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent(relativePath).path))
    }

    @Test
    func transcriptExportUsesCreatedAtRelativeTimestamps() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let meetingId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
        let relativePath = try TranscriptExportService.exportTranscript(
            vaultURL: vaultURL,
            meetingId: meetingId,
            projectName: "Test Project",
            createdAt: createdAt,
            segments: [
                TranscriptSegment(
                    startTime: createdAt.addingTimeInterval(754),
                    text: "hello"
                )
            ]
        )

        let markdown = try String(contentsOf: vaultURL.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(markdown.contains("###### 00:12:34\nhello"))
    }

    @Test
    func transcriptExportUsesRecordingSessionOffsetsAcrossPausedRecording() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let meetingId = UUID()
        let meetingStart = Date(timeIntervalSince1970: 1_776_384_000)
        let firstSessionId = UUID.v7()
        let secondSessionId = UUID.v7()
        let relativePath = try TranscriptExportService.exportTranscript(
            vaultURL: vaultURL,
            meetingId: meetingId,
            projectName: "Test Project",
            createdAt: meetingStart,
            segments: [
                TranscriptSegment(
                    sessionId: firstSessionId,
                    startTime: meetingStart.addingTimeInterval(5),
                    text: "before"
                ),
                TranscriptSegment(
                    sessionId: secondSessionId,
                    startTime: meetingStart.addingTimeInterval(303),
                    text: "after"
                ),
            ],
            recordingSessions: [
                RecordingSessionTimeline(
                    id: firstSessionId,
                    startedAt: meetingStart,
                    endedAt: meetingStart.addingTimeInterval(10),
                    offsetSeconds: 0
                ),
                RecordingSessionTimeline(
                    id: secondSessionId,
                    startedAt: meetingStart.addingTimeInterval(300),
                    endedAt: nil,
                    offsetSeconds: 10
                ),
            ]
        )

        let markdown = try String(contentsOf: vaultURL.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(markdown.contains("###### 00:00:05\nbefore"))
        #expect(markdown.contains("###### 00:00:13\nafter"))
    }

    @Test
    func screenshotExportWritesIntoDahliaScreenshotsDirectory() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let screenshot = MeetingScreenshotRecord(
            id: UUID(),
            meetingId: UUID(),
            capturedAt: Date(timeIntervalSince1970: 0),
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png"
        )

        let relativePaths = try ScreenshotExportService.exportScreenshots(
            vaultURL: vaultURL,
            screenshots: [screenshot]
        )

        #expect(relativePaths == ["_dahlia/screenshots/\(screenshot.id.uuidString).png"])
        #expect(FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent(relativePaths[0]).path))
    }
}
#endif
