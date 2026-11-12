import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BackupArchiveTests {
        @Test(arguments: ["valid", "duplicate", "traversal", "unexpected", "retiredFormat"])
        func archiveRoundTripAndManifestBoundary(kind: String) throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "archive-test-\(UUID.v7())")
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appending(path: "source")
            let filePath = "files/\(UUID.v7().uuidString.lowercased())/original"
            try FileManager.default.createDirectory(
                at: directory.appending(path: filePath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bytes = Data(repeating: 0xA7, count: 2_100_001)
            try bytes.write(to: directory.appending(path: filePath))
            try Data("database fixture".utf8).write(to: directory.appending(path: "database.sqlite"))
            try Data([1]).write(to: root.appending(path: "outside"))
            try Data([2]).write(to: directory.appending(path: "unexpected"))
            let metadata = BackupMetadata(
                formatVersion: kind == "retiredFormat" ? 4 : BackupMetadata.currentFormatVersion,
                generationId: .v7(),
                createdAt: .now,
                schemaVersion: AppDatabaseManager.currentSchemaVersion,
                migrationIdentifier: AppDatabaseManager.currentMigrationIdentifier,
                appVersion: "test",
                appBuild: "0",
                reason: .manual,
                workspaces: [BackupWorkspace(id: .v7(), name: "Local")]
            )
            var paths = ["database.sqlite", filePath]
            switch kind {
            case "duplicate": paths.append(filePath)
            case "traversal": paths.append("../outside")
            case "unexpected": paths.append("unexpected")
            default: break
            }
            let archive = root.appending(path: "test.tar.gz")
            let created = try BackupArchive.create(directory: directory, metadata: metadata, paths: paths, at: archive)
            if kind == "valid" {
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-tzf", archive.path]
                let output = Pipe()
                tar.standardOutput = output
                try tar.run()
                let listing = output.fileHandleForReading.readDataToEndOfFile()
                tar.waitUntilExit()
                #expect(tar.terminationStatus == 0)
                #expect(String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init) == ["manifest.json"] + paths)
                let extractedByTar = root.appending(path: "system-tar")
                try FileManager.default.createDirectory(at: extractedByTar, withIntermediateDirectories: false)
                let extraction = Process()
                extraction.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                extraction.arguments = ["-xzf", archive.path, "-C", extractedByTar.path]
                try extraction.run()
                extraction.waitUntilExit()
                #expect(extraction.terminationStatus == 0)
                #expect(try Data(contentsOf: extractedByTar.appending(path: filePath)) == bytes)
                #expect(try Data(contentsOf: extractedByTar.appending(path: "database.sqlite")) == Data("database fixture".utf8))
                try BackupArchive.verify(at: archive, matches: created)
                let otherManifest = BackupArchiveManifest(metadata: created.metadata, entries: Array(created.entries.prefix(1)))
                #expect(throws: BackupServiceError.invalidBackup) { try BackupArchive.verify(at: archive, matches: otherManifest) }
                try BackupArchive.withExtracted(at: archive) { extracted, manifest throws in
                    #expect(manifest.metadata == metadata)
                    #expect(manifest.entries.count == 2)
                    #expect(try Data(contentsOf: extracted.appending(path: filePath)) == bytes)
                }
                let complete = try Data(contentsOf: archive)
                for removedBytes in 1 ... 8 {
                    let incomplete = root.appending(path: "truncated-\(removedBytes).tar.gz")
                    try complete.dropLast(removedBytes).write(to: incomplete)
                    #expect(throws: (any Error).self) { try BackupArchive.verify(at: incomplete, matches: created) }
                }
                var truncated = try Data(contentsOf: archive)
                truncated.removeLast(min(128, truncated.count / 2))
                try truncated.write(to: archive)
                #expect(throws: (any Error).self) { try BackupArchive.withExtracted(at: archive) { _, _ in } }
                #expect(throws: (any Error).self) { try BackupArchive.verify(at: archive, matches: created) }
            } else {
                #expect(throws: BackupServiceError.invalidBackup) { try BackupArchive.withExtracted(at: archive) { _, _ in } }
                #expect(try Data(contentsOf: root.appending(path: "outside")) == Data([1]))
            }
        }

    }
#endif
