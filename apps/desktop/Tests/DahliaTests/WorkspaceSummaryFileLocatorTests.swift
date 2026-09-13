import Foundation
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct WorkspaceSummaryFileLocatorTests {
        @Test
        func storedPathResolvesWithoutReadingFrontmatter() throws {
            let workspaceURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let summaryURL = workspaceURL.appending(path: "Projects/Alpha/summary.md")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            try FileManager.default.createDirectory(at: summaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Summary".utf8).write(to: summaryURL, options: .atomic)

            let resolved = SummaryService.findSummaryFile(
                storedRelativePath: "Projects/Alpha/summary.md",
                workspaceURL: workspaceURL
            )

            #expect(resolved == summaryURL.standardizedFileURL)
        }

        @Test
        func staleStoredPathDoesNotSearchFrontmatter() throws {
            let workspaceURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let movedURL = workspaceURL.appending(path: "Archive/Renamed.md")
            let meetingId = UUID.v7()
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            try FileManager.default.createDirectory(at: movedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(
                """
                ---
                meeting_id: "\(meetingId.uuidString)"
                ---

                Summary
                """.utf8
            ).write(to: movedURL, options: .atomic)

            let resolved = SummaryService.findSummaryFile(
                storedRelativePath: "Projects/Alpha/Old.md",
                workspaceURL: workspaceURL
            )

            #expect(resolved == nil)
        }

        @Test
        func missingStoredPathDoesNotSearchWorkspace() throws {
            let workspaceURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let summaryURL = workspaceURL.appending(path: "Project/Summary.md")
            defer { try? FileManager.default.removeItem(at: workspaceURL) }

            try FileManager.default.createDirectory(at: summaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Summary".utf8).write(to: summaryURL, options: .atomic)

            let resolved = SummaryService.findSummaryFile(
                storedRelativePath: nil,
                workspaceURL: workspaceURL
            )

            #expect(resolved == nil)
        }
    }
#endif
