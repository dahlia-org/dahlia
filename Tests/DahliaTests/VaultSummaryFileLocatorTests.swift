import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct VaultSummaryFileLocatorTests {
        @Test
        func storedPathResolvesWithoutReadingFrontmatter() throws {
            let vaultURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let summaryURL = vaultURL.appending(path: "Projects/Alpha/summary.md")
            defer { try? FileManager.default.removeItem(at: vaultURL) }

            try FileManager.default.createDirectory(at: summaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Summary".utf8).write(to: summaryURL, options: .atomic)

            let resolved = SummaryService.findSummaryFile(
                storedRelativePath: "Projects/Alpha/summary.md",
                vaultURL: vaultURL
            )

            #expect(resolved == summaryURL.standardizedFileURL)
        }

        @Test
        func staleStoredPathDoesNotSearchFrontmatter() throws {
            let vaultURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let movedURL = vaultURL.appending(path: "Archive/Renamed.md")
            let meetingId = UUID.v7()
            defer { try? FileManager.default.removeItem(at: vaultURL) }

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
                vaultURL: vaultURL
            )

            #expect(resolved == nil)
        }

        @Test
        func missingStoredPathDoesNotSearchVault() throws {
            let vaultURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let summaryURL = vaultURL.appending(path: "Project/Summary.md")
            defer { try? FileManager.default.removeItem(at: vaultURL) }

            try FileManager.default.createDirectory(at: summaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Summary".utf8).write(to: summaryURL, options: .atomic)

            let resolved = SummaryService.findSummaryFile(
                storedRelativePath: nil,
                vaultURL: vaultURL
            )

            #expect(resolved == nil)
        }
    }
#endif
