import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    extension MeetingScreenshotRecord {
        /// Seeds the recoverable state produced by v45 when upgrading a released BLOB database.
        func insertLegacyForTesting(_ db: Database) throws {
            guard let bytes = imageData, let workspaceId = try MeetingRecord.fetchOne(db, key: meetingId)?.workspaceId else {
                try insert(db)
                return
            }
            try FileRecord(
                id: originalFileId,
                workspaceId: workspaceId,
                size: Int64(bytes.count),
                contentType: mimeType,
                checksum: "SHA-256:" + ScreenshotRemoteReference.digest(bytes),
                name: "capture",
                metadata: FileStorageMetadata(source: .screenshot),
                createdAt: capturedAt,
                updatedAt: capturedAt,
                localReference: localReference,
                remoteReference: remoteReference
            ).insert(db)
            try FileTextBodyRecord(fileId: originalFileId, ocrText: ocrText, caption: caption).insert(db)
            try MeetingAttachmentRecord(
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

#endif
