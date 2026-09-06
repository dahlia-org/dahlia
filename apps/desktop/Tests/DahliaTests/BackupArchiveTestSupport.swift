import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    func extractedBackupDatabase(_ url: URL) throws -> URL {
        try BackupArchive.withExtracted(at: url) { directory, _ in
            let copy = url.deletingLastPathComponent().appending(path: "test-\(UUID.v7()).sqlite")
            try FileManager.default.copyItem(at: directory.appending(path: "database.sqlite"), to: copy)
            return copy
        }
    }

    func editBackupDatabase(_ url: URL, _ body: (Database) throws -> Void) throws {
        try BackupArchive.withExtracted(at: url) { directory, manifest in
            let queue = try DatabaseQueue(path: directory.appending(path: "database.sqlite").path, configuration: AppDatabaseManager.configuration())
            try queue.write(body)
            try queue.close()
            let replacement = directory.appending(path: "edited.dahliabackup")
            try BackupArchive.create(directory: directory, metadata: manifest.metadata, paths: manifest.entries.map(\.path), at: replacement)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: replacement, to: url)
        }
    }
#endif
