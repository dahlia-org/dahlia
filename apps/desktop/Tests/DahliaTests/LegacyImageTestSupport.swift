import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    extension MeetingScreenshotRecord {
        /// Seeds the recoverable state produced by v45 when upgrading a released BLOB database.
        func insertLegacyForTesting(_ db: Database) throws {
            guard let bytes = imageData, let vaultId = try MeetingRecord.fetchOne(db, key: meetingId)?.vaultId else {
                try insert(db)
                return
            }
            try FileRecord(
                id: originalFileId,
                vaultId: vaultId,
                size: Int64(bytes.count),
                contentType: mimeType,
                checksum: "SHA-256:" + ScreenshotRemoteReference.digest(bytes),
                name: "capture",
                metadata: FileMetadata(source: .screenshot, ocrText: ocrText, caption: caption),
                createdAt: capturedAt,
                updatedAt: capturedAt,
                localReference: localReference,
                remoteReference: remoteReference
            ).insert(db)
            try MeetingFileRecord(
                id: id,
                meetingId: meetingId,
                fileId: originalFileId,
                capturedAt: capturedAt,
                sessionId: sessionId,
                createdAt: capturedAt
            ).insert(db)
            try db.execute(sql: "INSERT INTO file_migration_content VALUES (?, ?)", arguments: [originalFileId, bytes])
        }
    }

    func canonicalImageChanges(fileId: UUID, meetingId: UUID, ocr: String? = nil, caption: String? = nil) throws -> [SyncChangePage.Change] {
        let file: [String: JSONValue] = [
            "uri": .string("/Volumes/catalog/schema/volume/files/\(fileId.uuidString.lowercased())/original"),
            "offset": .number(0), "size": .number(3), "content_type": .string("image/png"),
            "checksum": .string("SHA-256:" + ScreenshotRemoteReference.digest(Data([1, 2, 3]))),
            "name": .string("capture"), "createdAt": .string("2026-09-06T00:00:00Z"), "updatedAt": .string("2026-09-06T00:00:00Z"),
            "metadata": .object([
                "source": .string("screenshot"),
                "ocr_text": ocr.map(JSONValue.string) ?? .null,
                "caption": caption.map(JSONValue.string) ?? .null,
            ]),
        ]
        let link: [String: JSONValue] = [
            "meetingId": .string(meetingId.uuidString),
            "fileId": .string(fileId.uuidString),
            "createdAt": .string("2026-09-06T00:00:00Z"),
            "capturedAt": .string("2026-09-06T00:00:00Z"),
        ]
        return try [(SyncEntity.file, file), (.meetingFile, link)].enumerated().map { index, item in
            try SyncChangePage.Change(
                sequence: index + 2,
                entity: item.0,
                entityId: fileId,
                action: "upsert",
                revision: 1,
                record: SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: JSONEncoder().encode(item.1))
            )
        }
    }
#endif
