import Foundation
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct WorkspaceSummaryExportServiceTests {
        @MainActor
        @Test
        func supportingArtifactExportsDoNotBlockMainActor() async throws {
            let ranOnMainThread = OSAllocatedUnfairLock(initialState: false)
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: .v7(),
                capturedAt: .now,
                imageData: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "image/png"
            )

            try await WorkspaceSummaryExportService.exportSupportingArtifacts(
                workspaceURL: FileManager.default.temporaryDirectory,
                meetingId: .v7(),
                projectName: "Project",
                createdAt: .now,
                segments: [],
                recordingSessions: [],
                screenshots: [screenshot],
                exportTranscript: { _, _, _, _, _, _ in
                    ranOnMainThread.withLock { $0 = $0 || Thread.isMainThread }
                    return ""
                },
                exportScreenshots: { _, _ in
                    ranOnMainThread.withLock { $0 = $0 || Thread.isMainThread }
                    return []
                }
            )

            let didRunOnMainThread = ranOnMainThread.withLock { $0 }
            #expect(!didRunOnMainThread)
        }

        @MainActor
        @Test
        func lockedSummaryExportWorkDoesNotRunOnMainActor() async throws {
            let workspaceURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: workspaceURL) }
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            let ranOnMainThread = OSAllocatedUnfairLock(initialState: false)

            try await WorkspaceSummaryExportService.withWorkspaceMutationLock(
                workspaceURL: workspaceURL,
                workspaceID: .v7()
            ) {
                ranOnMainThread.withLock { $0 = Thread.isMainThread }
            }

            let didRunOnMainThread = ranOnMainThread.withLock { $0 }
            #expect(!didRunOnMainThread)
        }

        @Test
        func exportSummaryBundleWritesSummaryTranscriptAndScreenshots() async throws {
            let workspaceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let projectURL = workspaceURL.appendingPathComponent("Project", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

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

            let summaryURL = try await WorkspaceSummaryExportService.exportSummaryBundle(
                projectURL: projectURL,
                workspaceURL: workspaceURL,
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
            #expect(
                (try? projectURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            )
            #expect(try String(contentsOf: summaryURL, encoding: .utf8) == summaryMarkdown)
            #expect(FileManager.default
                .fileExists(atPath: workspaceURL.appendingPathComponent("_dahlia/transcripts/\(meetingId.uuidString).md").path))
            #expect(
                FileManager.default.fileExists(
                    atPath: workspaceURL.appendingPathComponent("_dahlia/screenshots/\(screenshot.id.uuidString).png").path
                )
            )
        }

        @Test
        func summaryOutputRejectsProjectSymlinkOutsideWorkspace() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
            let outsideURL = rootURL.appendingPathComponent("Outside", isDirectory: true)
            let projectURL = workspaceURL.appendingPathComponent("Project", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: projectURL, withDestinationURL: outsideURL)

            #expect(throws: ProjectWorkspaceError.invalidSummaryOutputDestination) {
                try WorkspaceSummaryExportService.resolveSummaryFileURL(
                    projectURL: projectURL,
                    workspaceURL: workspaceURL,
                    storedSummaryRelativePath: nil,
                    meetingId: UUID(),
                    summaryFileName: "Summary.md"
                )
            }
            #expect(!FileManager.default.fileExists(atPath: outsideURL.appendingPathComponent("Summary.md").path))

            try Data("Existing".utf8).write(
                to: outsideURL.appendingPathComponent("Existing.md"),
                options: .atomic
            )
            #expect(throws: ProjectWorkspaceError.invalidSummaryOutputDestination) {
                try WorkspaceSummaryExportService.resolveSummaryFileURL(
                    projectURL: projectURL,
                    workspaceURL: workspaceURL,
                    storedSummaryRelativePath: "Project/Existing.md",
                    meetingId: UUID(),
                    summaryFileName: "Summary.md"
                )
            }
        }

        @Test
        func exportSummaryBundleReusesStoredSummaryPath() async throws {
            let workspaceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let projectURL = workspaceURL.appendingPathComponent("Project", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

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

            let summaryURL = try await WorkspaceSummaryExportService.exportSummaryBundle(
                projectURL: projectURL,
                workspaceURL: workspaceURL,
                storedSummaryRelativePath: "Project/existing-summary.md",
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
        func newSummaryDoesNotOverwriteExistingFile() async throws {
            let workspaceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let projectURL = workspaceURL.appendingPathComponent("Project", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: workspaceURL) }
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let existingURL = projectURL.appendingPathComponent("summary.md")
            try Data("Existing".utf8).write(to: existingURL, options: .atomic)
            let meetingId = UUID()

            let summaryURL = try await WorkspaceSummaryExportService.exportSummaryBundle(
                projectURL: projectURL,
                workspaceURL: workspaceURL,
                meetingId: meetingId,
                createdAt: Date(timeIntervalSince1970: 0),
                projectName: "Test Project",
                segments: [],
                screenshots: [],
                summaryFileName: "summary.md",
                summaryMarkdown: "New"
            )

            #expect(try String(contentsOf: existingURL, encoding: .utf8) == "Existing")
            #expect(summaryURL.lastPathComponent == "summary-\(meetingId.uuidString).md")
            #expect(try String(contentsOf: summaryURL, encoding: .utf8) == "New")
        }

        @Test
        func exportSummaryBundleFailsWhenAnyArtifactExportFails() async throws {
            enum ExpectedError: Error {
                case transcriptFailed
            }

            let workspaceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let projectURL = workspaceURL.appendingPathComponent("Project", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

            var didThrowExpectedError = false

            do {
                _ = try await WorkspaceSummaryExportService.exportSummaryBundle(
                    projectURL: projectURL,
                    workspaceURL: workspaceURL,
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

        @Test
        func screenshotDeletionRemovesExportedImage() throws {
            let workspaceURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: .v7(),
                capturedAt: .now,
                imageData: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "image/png"
            )
            _ = try ScreenshotExportService.exportScreenshots(workspaceURL: workspaceURL, screenshots: [screenshot])
            let screenshotURL = ScreenshotExportService.screenshotsDirectoryURL(in: workspaceURL)
                .appending(path: ScreenshotExportService.filename(for: screenshot))

            try ScreenshotExportService.deleteExportedScreenshots(
                workspaceURL: workspaceURL,
                screenshots: [screenshot]
            )

            #expect(!FileManager.default.fileExists(atPath: screenshotURL.path))
        }
    }
#endif
