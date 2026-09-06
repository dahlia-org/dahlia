import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BackupArchiveTests {
        @Test(arguments: ["valid", "duplicate", "traversal", "unexpected"])
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
                formatVersion: 4,
                generationId: .v7(),
                createdAt: .now,
                schemaVersion: AppDatabaseManager.currentSchemaVersion,
                migrationIdentifier: AppDatabaseManager.currentMigrationIdentifier,
                appVersion: "test",
                appBuild: "0",
                reason: .manual,
                vaults: [BackupVault(id: .v7(), name: "Local")]
            )
            var paths = ["database.sqlite", filePath]
            switch kind {
            case "duplicate": paths.append(filePath)
            case "traversal": paths.append("../outside")
            case "unexpected": paths.append("unexpected")
            default: break
            }
            let archive = root.appending(path: "test.dahliabackup")
            try BackupArchive.create(directory: directory, metadata: metadata, paths: paths, at: archive)
            if kind == "valid" {
                try BackupArchive.withExtracted(at: archive) { extracted, manifest throws in
                    #expect(manifest.metadata == metadata)
                    #expect(manifest.entries.count == 2)
                    #expect(try Data(contentsOf: extracted.appending(path: filePath)) == bytes)
                }
                var truncated = try Data(contentsOf: archive)
                truncated.removeLast(min(128, truncated.count / 2))
                try truncated.write(to: archive)
                #expect(throws: (any Error).self) { try BackupArchive.withExtracted(at: archive) { _, _ in } }
            } else {
                #expect(throws: BackupServiceError.invalidBackup) { try BackupArchive.withExtracted(at: archive) { _, _ in } }
                #expect(try Data(contentsOf: root.appending(path: "outside")) == Data([1]))
            }
        }
    }
#endif
