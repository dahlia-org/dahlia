import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

struct VaultSummaryExportServiceTests {
    @Test
    func exportSummaryBundleWritesSummaryTranscriptAndScreenshots() async throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = vaultURL.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let meetingId = UUID()
        let screenshot = MeetingScreenshotRecord(
            id: UUID(),
            meetingId: meetingId,
            capturedAt: Date(timeIntervalSince1970: 0),
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png"
        )
        let summaryMarkdown = """
        ---
        meeting_id: "\(meetingId.uuidString)"
        ---

        Summary body
        """

        let summaryURL = try await VaultSummaryExportService.exportSummaryBundle(
            projectURL: projectURL,
            vaultURL: vaultURL,
            meetingId: meetingId,
            createdAt: Date(timeIntervalSince1970: 0),
            projectName: "Test Project",
            segments: [
                TranscriptSegment(
                    startTime: Date(timeIntervalSince1970: 0),
                    text: "hello"
                ),
            ],
            screenshots: [screenshot],
            summaryFileName: "summary.md",
            summaryMarkdown: summaryMarkdown
        )

        #expect(summaryURL == projectURL.appendingPathComponent("summary.md"))
        #expect(try String(contentsOf: summaryURL, encoding: .utf8) == summaryMarkdown)
        #expect(FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent("_dahlia/transcripts/\(meetingId.uuidString).md").path))
        #expect(
            FileManager.default.fileExists(
                atPath: vaultURL.appendingPathComponent("_dahlia/screenshots/\(screenshot.id.uuidString).png").path
            )
        )
    }

    @Test
    func exportSummaryBundleReusesExistingSummaryFileForMeetingID() async throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = vaultURL.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let meetingId = UUID()
        let existingSummaryURL = projectURL.appendingPathComponent("existing-summary.md")
        try Data(
            """
            ---
            meeting_id: "\(meetingId.uuidString)"
            ---

            Old body
            """.utf8
        ).write(to: existingSummaryURL, options: .atomic)

        let summaryMarkdown = """
        ---
        meeting_id: "\(meetingId.uuidString)"
        ---

        New body
        """

        let summaryURL = try await VaultSummaryExportService.exportSummaryBundle(
            projectURL: projectURL,
            vaultURL: vaultURL,
            meetingId: meetingId,
            createdAt: Date(timeIntervalSince1970: 0),
            projectName: "Test Project",
            segments: [],
            screenshots: [],
            summaryFileName: "new-summary.md",
            summaryMarkdown: summaryMarkdown
        )

        #expect(summaryURL.resolvingSymlinksInPath() == existingSummaryURL.resolvingSymlinksInPath())
        #expect(try String(contentsOf: existingSummaryURL, encoding: .utf8) == summaryMarkdown)
        #expect(!FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("new-summary.md").path))
    }

    @Test
    func exportSummaryBundleFailsWhenAnyArtifactExportFails() async throws {
        enum ExpectedError: Error {
            case transcriptFailed
        }

        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = vaultURL.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        var didThrowExpectedError = false

        do {
            _ = try await VaultSummaryExportService.exportSummaryBundle(
                projectURL: projectURL,
                vaultURL: vaultURL,
                meetingId: UUID(),
                createdAt: Date(timeIntervalSince1970: 0),
                projectName: "Test Project",
                segments: [],
                screenshots: [],
                summaryFileName: "summary.md",
                summaryMarkdown: "summary",
                exportTranscript: { _, _, _, _, _, _ in
                    throw ExpectedError.transcriptFailed
                },
                exportScreenshots: { _, _ in [] },
                writeSummary: { fileURL, markdown in
                    try Data(markdown.utf8).write(to: fileURL, options: .atomic)
                    return fileURL
                }
            )
        } catch is ExpectedError {
            didThrowExpectedError = true
        }

        #expect(didThrowExpectedError)
    }
}
#endif
