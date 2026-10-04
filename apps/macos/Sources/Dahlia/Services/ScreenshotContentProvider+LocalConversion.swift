import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

extension ScreenshotContentProvider {
    static let localScreenshotConversionCompletedKey = "localScreenshotConversionCompleted"

    /// Re-encodes local-workspace screenshots saved before the WebP format and long-edge limit, once per install.
    func startLocalScreenshotConversionIfNeeded(dbQueue: DatabaseQueue) {
        guard !UserDefaults.standard.bool(forKey: Self.localScreenshotConversionCompletedKey) else { return }
        Task(priority: .utility) {
            do {
                try await convertLocalScreenshots(dbQueue: dbQueue)
                UserDefaults.standard.set(true, forKey: Self.localScreenshotConversionCompletedKey)
            } catch {
                ErrorReportingService.capture(error, context: ["source": "localScreenshotConversion"])
            }
        }
    }

    /// Files are immutable and verified by hash, so each converted image gets a new file ID. Its references move in
    /// one transaction, so an interrupted run never leaves an unreadable screenshot and resumes on the next launch.
    func convertLocalScreenshots(dbQueue: DatabaseQueue) async throws {
        let ids = try await dbQueue.read { db in
            try UUID.fetchAll(db, sql: """
            SELECT f.id FROM files f JOIN workspaces v ON v.id = f.workspace_id
            WHERE v.accountConnectionId IS NULL AND f.remoteReference IS NULL
                AND json_extract(f.metadata, '$.source') = 'screenshot'
                AND EXISTS(SELECT 1 FROM meeting_attachments a WHERE a.fileId = f.id)
            ORDER BY f.id
            """)
        }
        for id in ids {
            try Task.checkCancellation()
            // One unreadable file must not keep every later launch rescanning the library.
            do {
                try await convertLocalScreenshot(id: id, dbQueue: dbQueue)
            } catch {
                ErrorReportingService.capture(error, context: ["source": "localScreenshotConversion"])
            }
        }
    }

    private func convertLocalScreenshot(id: UUID, dbQueue: DatabaseQueue) async throws {
        activeFileWork += 1
        defer { activeFileWork -= 1 }
        guard let file = try await dbQueue.read({ try FileRecord.fetchOne($0, key: id) }) else { return }
        let original = try await fileContent(id: id, dbQueue: dbQueue, recordAccess: false)
        guard let size = ImageEncoder.pixelSize(of: original.data) else { throw ScreenshotContentError.integrityFailure }
        guard ImageEncoder.mimeType(for: original.data) != "image/webp"
            || max(size.width, size.height) > ImageEncoder.screenshotMaximumLongEdge else { return }
        guard let data = await Self.reencoded(original.data),
              let mimeType = ImageEncoder.mimeType(for: data),
              let convertedSize = ImageEncoder.pixelSize(of: data) else { throw ScreenshotContentError.integrityFailure }

        let source = ScreenshotRemoteReference(
            origin: "",
            accountConnectionId: nil,
            fileId: .v7(),
            contentHash: ScreenshotRemoteReference.digest(data)
        )
        let files = try fileStore(for: dbQueue)
        try files.write(
            ScreenshotContent(data: data, mimeType: mimeType, variant: .original),
            source: source,
            required: true,
            recordAccess: false
        )
        let reference = try source.jsonString()
        let moved: Bool
        do {
            moved = try await dbQueue.write { db -> Bool in
                guard let current = try FileRecord.fetchOne(db, key: id), current.checksum == file.checksum,
                      current.localReference == file.localReference, current.remoteReference == nil,
                      try WorkspaceRecord.fetchOne(db, key: file.workspaceId)?.accountConnectionId == nil else { return false }
                var converted = current
                converted.id = source.fileId
                converted.size = Int64(data.count)
                converted.contentType = mimeType
                converted.checksum = "SHA-256:" + source.contentHash
                converted.name = "capture.\(mimeType.split(separator: "/").last ?? "bin")"
                converted.metadata.width = convertedSize.width
                converted.metadata.height = convertedSize.height
                converted.updatedAt = .now
                converted.localReference = reference
                try converted.insert(db)
                let text = try FileTextBodyRecord.fetchOne(db, key: id)
                try FileTextBodyRecord(fileId: source.fileId, ocrText: text?.ocrText, caption: text?.caption).insert(db)
                try db.execute(sql: "UPDATE meeting_attachments SET fileId = ? WHERE fileId = ?", arguments: [source.fileId, id])
                try FileRecord.deleteOne(db, key: id)
                return true
            }
        } catch {
            try? files.remove(source)
            throw error
        }
        guard moved else {
            try files.remove(source)
            return
        }
        // ponytail: a crash right here leaves the old file unreferenced on disk; sweep orphans if that ever matters.
        if let oldReference = file.localReference {
            try files.remove(JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(oldReference.utf8)))
        }
    }

    @concurrent private nonisolated static func reencoded(_ data: Data) async -> Data? {
        ImageEncoder.resizedIfPossible(data, maxLongEdge: ImageEncoder.screenshotMaximumLongEdge)
    }
}
