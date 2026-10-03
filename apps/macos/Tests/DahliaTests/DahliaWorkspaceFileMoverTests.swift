import Foundation
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct DahliaWorkspaceFileMoverTests {
        @Test
        func movesRegularFileWithinWorkspace() throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let source = fixture.workspaceURL.appending(path: "Source.md")
            let destination = fixture.workspaceURL.appending(path: "Destination/Summary.md")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: false
            )
            try Data("Summary".utf8).write(to: source)

            try DahliaWorkspaceFileMover.moveItem(
                at: source,
                to: destination,
                inside: fixture.workspaceURL
            )

            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(try String(contentsOf: destination, encoding: .utf8) == "Summary")
        }

        @Test
        func rejectsDestinationParentSymlinkOutsideWorkspace() throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let source = fixture.workspaceURL.appending(path: "Source.md")
            let outside = fixture.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            let link = fixture.workspaceURL.appending(path: "Link", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            try Data("Summary".utf8).write(to: source)

            #expect(throws: (any Error).self) {
                try DahliaWorkspaceFileMover.moveItem(
                    at: source,
                    to: link.appending(path: "Summary.md"),
                    inside: fixture.workspaceURL
                )
            }

            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "Summary.md").path))
        }

        @Test
        func neverOverwritesDifferentDestinationFile() throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let source = fixture.workspaceURL.appending(path: "Source.md")
            let destination = fixture.workspaceURL.appending(path: "Destination.md")
            try Data("Source".utf8).write(to: source)
            try Data("Destination".utf8).write(to: destination)

            #expect(throws: POSIXError(.EEXIST)) {
                try DahliaWorkspaceFileMover.moveItem(
                    at: source,
                    to: destination,
                    inside: fixture.workspaceURL
                )
            }

            #expect(try String(contentsOf: source, encoding: .utf8) == "Source")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "Destination")
        }
    }

    private extension DahliaWorkspaceFileMoverTests {
        struct Fixture {
            let rootURL: URL
            let workspaceURL: URL

            init() throws {
                rootURL = URL.temporaryDirectory
                    .appending(path: "dahlia-workspace-mover-\(UUID())", directoryHint: .isDirectory)
                workspaceURL = rootURL.appending(path: "Workspace", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            }

            func removeFiles() {
                try? FileManager.default.removeItem(at: rootURL)
            }
        }
    }
#endif
