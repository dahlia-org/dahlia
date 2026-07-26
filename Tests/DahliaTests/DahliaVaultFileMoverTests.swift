import Foundation
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct DahliaVaultFileMoverTests {
        @Test
        func movesRegularFileWithinVault() throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let source = fixture.vaultURL.appending(path: "Source.md")
            let destination = fixture.vaultURL.appending(path: "Destination/Summary.md")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: false
            )
            try Data("Summary".utf8).write(to: source)

            try DahliaVaultFileMover.moveItem(
                at: source,
                to: destination,
                inside: fixture.vaultURL
            )

            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(try String(contentsOf: destination, encoding: .utf8) == "Summary")
        }

        @Test
        func rejectsDestinationParentSymlinkOutsideVault() throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let source = fixture.vaultURL.appending(path: "Source.md")
            let outside = fixture.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            let link = fixture.vaultURL.appending(path: "Link", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            try Data("Summary".utf8).write(to: source)

            #expect(throws: (any Error).self) {
                try DahliaVaultFileMover.moveItem(
                    at: source,
                    to: link.appending(path: "Summary.md"),
                    inside: fixture.vaultURL
                )
            }

            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "Summary.md").path))
        }

        @Test
        func neverOverwritesDifferentDestinationFile() throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let source = fixture.vaultURL.appending(path: "Source.md")
            let destination = fixture.vaultURL.appending(path: "Destination.md")
            try Data("Source".utf8).write(to: source)
            try Data("Destination".utf8).write(to: destination)

            #expect(throws: POSIXError(.EEXIST)) {
                try DahliaVaultFileMover.moveItem(
                    at: source,
                    to: destination,
                    inside: fixture.vaultURL
                )
            }

            #expect(try String(contentsOf: source, encoding: .utf8) == "Source")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "Destination")
        }
    }

    private extension DahliaVaultFileMoverTests {
        struct Fixture {
            let rootURL: URL
            let vaultURL: URL

            init() throws {
                rootURL = URL.temporaryDirectory
                    .appending(path: "dahlia-vault-mover-\(UUID())", directoryHint: .isDirectory)
                vaultURL = rootURL.appending(path: "Vault", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            }

            func removeFiles() {
                try? FileManager.default.removeItem(at: rootURL)
            }
        }
    }
#endif
