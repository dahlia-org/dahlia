import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

enum SyncInitialSnapshotBuilder {
    private static let projectBatchSize = 100

    static func enqueuePending(
        dbQueue: DatabaseQueue,
        screenshotContent: ScreenshotContentProvider = .shared,
        onFailure: @Sendable (any Error) throws -> Void = { throw $0 }
    ) async throws {
        let interruptedWorkspaceId = try await dbQueue.read { db in
            try UUID.fetchOne(
                db,
                sql: """
                SELECT id FROM workspaces
                WHERE accountConnectionId IS NOT NULL
                  AND syncConfirmedConnectionId = accountConnectionId
                  AND syncRole = 'admin'
                  AND NOT EXISTS (
                    SELECT 1 FROM sync_transactions t WHERE t.workspace_id = workspaces.id
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM sync_entity_state s
                    WHERE s.workspace_id = workspaces.id AND s.entity = 'workspace' AND s.entityId = workspaces.id
                  )
                ORDER BY createdAt, id
                LIMIT 1
                """
            )
        }
        if let interruptedWorkspaceId {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE workspaces SET syncConfirmedConnectionId = NULL,
                        syncPullCursor = NULL, syncLastCommittedCursor = NULL
                    WHERE id = ?
                      AND accountConnectionId IS NOT NULL
                      AND syncConfirmedConnectionId = accountConnectionId
                      AND syncRole = 'admin'
                      AND NOT EXISTS (
                        SELECT 1 FROM sync_transactions t WHERE t.workspace_id = workspaces.id
                      )
                      AND NOT EXISTS (
                        SELECT 1 FROM sync_entity_state s
                        WHERE s.workspace_id = workspaces.id AND s.entity = 'workspace' AND s.entityId = workspaces.id
                      )
                    """,
                    arguments: [interruptedWorkspaceId]
                )
            }
        }

        let pending = try await dbQueue.read { db -> [(UUID, UUID, Bool)] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT v.id, v.accountConnectionId, EXISTS (
                    SELECT 1 FROM sync_transactions t
                    JOIN sync_operations o ON o.transactionId = t.id
                    WHERE t.workspace_id = v.id AND o.entity = 'workspace' AND o.action = 'reset'
                ) AS restoring
                FROM workspaces v
                WHERE v.accountConnectionId IS NOT NULL
                  AND v.syncConfirmedConnectionId IS NULL
                  AND v.syncRole = 'admin'
                  AND (
                    EXISTS (
                      SELECT 1 FROM sync_transactions t
                      JOIN sync_operations o ON o.transactionId = t.id
                      WHERE t.workspace_id = v.id AND o.entity = 'workspace' AND o.action = 'reset'
                    )
                    OR NOT EXISTS (
                      SELECT 1 FROM sync_entity_state s
                      WHERE s.workspace_id = v.id AND s.entity = 'workspace' AND s.entityId = v.id
                    )
                  )
                ORDER BY v.createdAt, v.id
                """
            ).map { ($0["id"], $0["accountConnectionId"], $0["restoring"]) }
        }
        for (workspaceId, connectionId, restoring) in pending {
            do {
                if try await enqueue(
                    workspaceId: workspaceId, connectionId: connectionId, restoring: restoring,
                    dbQueue: dbQueue, screenshotContent: screenshotContent
                ) { return }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Background synchronization can report this Workspace's failure and continue other Workspaces.
                // Explicit recovery callers keep the default throwing behavior.
                try onFailure(error)
            }
        }
    }

    private static func enqueue(
        workspaceId: UUID,
        connectionId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue,
        screenshotContent: ScreenshotContentProvider
    ) async throws -> Bool {
        screenshotContent.retainOriginals(workspaceIds: [workspaceId], dbQueue: dbQueue)
        defer { screenshotContent.releaseOriginals(workspaceIds: [workspaceId], dbQueue: dbQueue) }
        try await screenshotContent.prepareOriginals(workspaceId: workspaceId, dbQueue: dbQueue)
        guard let markerId = try await dbQueue.write({ db -> UUID? in
            guard try !RecordingSessionRecord.hasActiveRecording(workspaceId: workspaceId, in: db),
                  let workspace = try WorkspaceRecord.fetchOne(db, key: workspaceId),
                  workspace.accountConnectionId == connectionId,
                  workspace.syncConfirmedConnectionId == nil else { return nil }
            try SyncTransactionQueue.discard(workspaceId: workspaceId, in: db)
            if restoring {
                try SyncTransactionRecorder.record(
                    workspaceId: workspaceId,
                    operations: [restoreResetOperation(workspaceId: workspaceId)],
                    allowAfterReset: true,
                    connectionIdOverride: connectionId,
                    in: db
                )
            }
            return try SyncTransactionRecorder.record(
                workspaceId: workspaceId,
                operations: [workspaceOperation(workspace, action: .create)],
                allowAfterReset: restoring,
                connectionIdOverride: connectionId,
                in: db
            )
        }) else { return false }

        try await enqueueProjects(
            workspaceId: workspaceId,
            connectionId: connectionId,
            markerId: markerId,
            restoring: restoring,
            dbQueue: dbQueue
        )
        try await enqueueMeetings(
            workspaceId: workspaceId,
            connectionId: connectionId,
            markerId: markerId,
            restoring: restoring,
            dbQueue: dbQueue
        )
        try await enqueueFiles(workspaceId: workspaceId, connectionId: connectionId, markerId: markerId, restoring: restoring, dbQueue: dbQueue)
        try await enqueueScreenshots(
            workspaceId: workspaceId, connectionId: connectionId, markerId: markerId, restoring: restoring, dbQueue: dbQueue
        )

        return try await dbQueue.write { db in
            guard try canContinue(markerId: markerId, workspaceId: workspaceId, in: db) else { return false }
            if restoring {
                try db.execute(sql: "DELETE FROM sync_entity_state WHERE workspace_id = ?", arguments: [workspaceId])
            }
            try db.execute(
                sql: """
                UPDATE workspaces SET syncConfirmedConnectionId = accountConnectionId
                WHERE id = ? AND accountConnectionId = ? AND syncConfirmedConnectionId IS NULL
                """,
                arguments: [workspaceId, connectionId]
            )
            return db.changesCount == 1
        }
    }

    private static func enqueueProjects(
        workspaceId: UUID,
        connectionId: UUID,
        markerId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue
    ) async throws {
        for roots in [true, false] {
            var lastId: UUID?
            while true {
                try Task.checkCancellation()
                let cursor = lastId
                let projects = try await dbQueue.write { db -> [ProjectRecord] in
                    guard try canContinue(markerId: markerId, workspaceId: workspaceId, in: db) else { return [] }
                    let parentClause = roots ? "parentProjectId IS NULL" : "parentProjectId IS NOT NULL"
                    let cursorClause = cursor == nil ? "" : "AND id > ?"
                    var arguments: StatementArguments = [workspaceId]
                    if let cursor { arguments += [cursor] }
                    let projects = try ProjectRecord.fetchAll(
                        db,
                        sql: """
                        SELECT * FROM projects
                        WHERE workspace_id = ? AND \(parentClause) \(cursorClause)
                        ORDER BY id LIMIT \(projectBatchSize)
                        """,
                        arguments: arguments
                    )
                    try SyncTransactionRecorder.recordBatches(
                        workspaceId: workspaceId,
                        operations: projects.map { try projectOperation($0, action: .create) },
                        allowAfterReset: restoring,
                        connectionIdOverride: connectionId,
                        in: db
                    )
                    return projects
                }
                guard let nextId = projects.last?.id else { break }
                lastId = nextId
            }
        }
    }

    private static func enqueueMeetings(
        workspaceId: UUID,
        connectionId: UUID,
        markerId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue
    ) async throws {
        var lastMeetingId: UUID?
        while true {
            try Task.checkCancellation()
            let cursor = lastMeetingId
            let meeting = try await dbQueue.write { db -> MeetingRecord? in
                guard try canContinue(markerId: markerId, workspaceId: workspaceId, in: db) else { return nil }
                let meeting = if let cursor {
                    try MeetingRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM meetings WHERE workspace_id = ? AND id > ? ORDER BY id LIMIT 1",
                        arguments: [workspaceId, cursor]
                    )
                } else {
                    try MeetingRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM meetings WHERE workspace_id = ? ORDER BY id LIMIT 1",
                        arguments: [workspaceId]
                    )
                }
                guard let meeting else { return nil }
                try TextContentAccess.requireComplete(entity: .summary, id: meeting.id, in: db)
                try TextContentAccess.requireComplete(entity: .transcript, id: meeting.id, in: db)
                var metadata = try [meetingOperation(meeting, action: .create, in: db)]
                if let summary = try SummaryContent.fetchOne(db, key: meeting.id) {
                    try metadata.append(summaryOperation(summary, action: .upsert))
                }
                try SyncTransactionRecorder.record(
                    workspaceId: workspaceId,
                    operations: metadata,
                    allowAfterReset: restoring,
                    connectionIdOverride: connectionId,
                    in: db
                )
                return meeting
            }
            guard let meeting else { break }
            lastMeetingId = meeting.id

            try await enqueueTranscript(
                meetingId: meeting.id,
                workspaceId: workspaceId,
                connectionId: connectionId,
                markerId: markerId,
                restoring: restoring,
                dbQueue: dbQueue
            )
        }
    }

    private static func enqueueTranscript(
        meetingId: UUID,
        workspaceId: UUID,
        connectionId: UUID,
        markerId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue
    ) async throws {
        try await dbQueue.write { db in
            guard try canContinue(markerId: markerId, workspaceId: workspaceId, in: db) else { return }
            let previous = try TranscriptRecord.current(meetingId, in: db)
            let count = try TranscriptSegmentRecord.filter(Column("meetingId") == meetingId).fetchCount(db)
            guard previous != nil || count > 0 else { return }
            var info = previous ?? TranscriptInfo(id: .v7(), status: "completed", startedAt: nil, completedAt: nil, metadata: nil)
            info.id = .v7()
            info.version = nil
            info.syncRevision = nil
            try TranscriptRecord(meetingId: meetingId, info: info).save(db)
            try TranscriptRecord.enqueueSnapshot(
                meetingId: meetingId,
                info: info,
                allowAfterReset: restoring,
                connectionId: connectionId,
                in: db
            )
        }
    }

    private static func enqueueScreenshots(
        workspaceId: UUID,
        connectionId: UUID,
        markerId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue
    ) async throws {
        var lastScreenshotId: UUID?
        while true {
            try Task.checkCancellation()
            let cursor = lastScreenshotId
            let screenshot = try await dbQueue.write { db -> MeetingAttachmentRecord? in
                guard try canContinue(markerId: markerId, workspaceId: workspaceId, in: db) else { return nil }
                // Walk the attachment ID index instead of sorting every meeting's candidate for each row.
                let screenshot = if let cursor {
                    try MeetingAttachmentRecord.fetchOne(
                        db,
                        sql: """
                        SELECT a.* FROM meeting_attachments a
                        WHERE EXISTS (SELECT 1 FROM meetings m WHERE m.id = a.meetingId AND m.workspace_id = ?)
                          AND a.id > ? ORDER BY a.id LIMIT 1
                        """,
                        arguments: [workspaceId, cursor]
                    )
                } else {
                    try MeetingAttachmentRecord.fetchOne(
                        db,
                        sql: """
                        SELECT a.* FROM meeting_attachments a
                        WHERE EXISTS (SELECT 1 FROM meetings m WHERE m.id = a.meetingId AND m.workspace_id = ?)
                        ORDER BY a.id LIMIT 1
                        """,
                        arguments: [workspaceId]
                    )
                }
                guard let screenshot else { return nil }
                let operation = try meetingAttachmentOperation(screenshot)
                try SyncTransactionRecorder.record(
                    workspaceId: workspaceId,
                    operations: [operation],
                    allowAfterReset: restoring,
                    connectionIdOverride: connectionId,
                    in: db
                )
                return screenshot
            }
            guard let screenshot else { break }
            lastScreenshotId = screenshot.id
        }
    }

    static func prepareRestore(dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            let workspaceIds = try UUID.fetchAll(
                db,
                sql: """
                SELECT id FROM workspaces
                WHERE syncConfirmedConnectionId IS NOT NULL
                  AND syncRole = 'admin'
                """
            )
            for workspaceId in workspaceIds {
                try SyncTransactionQueue.discard(workspaceId: workspaceId, in: db)
                try SyncTransactionRecorder.record(
                    workspaceId: workspaceId,
                    operations: [restoreResetOperation(workspaceId: workspaceId)],
                    in: db
                )
                try db.execute(
                    sql: """
                    UPDATE workspaces SET syncConfirmedConnectionId = NULL,
                        syncPullCursor = NULL, syncLastCommittedCursor = NULL
                    WHERE id = ?
                    """,
                    arguments: [workspaceId]
                )
            }
        }
    }

    private static func canContinue(markerId: UUID, workspaceId: UUID, in db: Database) throws -> Bool {
        let markerExists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sync_transactions WHERE id = ? AND workspace_id = ?)",
            arguments: [markerId, workspaceId]
        ) ?? false
        guard markerExists else { return false }
        if try RecordingSessionRecord.hasActiveRecording(workspaceId: workspaceId, in: db) {
            try SyncTransactionQueue.discardPartialSnapshot(workspaceId: workspaceId, in: db)
            return false
        }
        return true
    }

    private static func restoreResetOperation(workspaceId: UUID) throws -> SyncOperationDraft {
        try SyncOperationDraft(
            entity: .workspace,
            action: .reset,
            entityId: workspaceId,
            payloadJSON: SyncJSON.encoder.encode(["preservePermissions": true])
        )
    }

    static func meetingOperation(_ meeting: MeetingRecord, action: SyncAction, in db: Database) throws -> SyncOperationDraft {
        var payload: [String: Any] = [
            "projectId": json(meeting.projectId),
            "name": meeting.name,
            "description": meeting.description,
            "status": meeting.status.rawValue,
            "duration": json(meeting.duration),
            "recordingStartedAt": json(meeting.recordingStartedAt),
            "updatedAt": meeting.updatedAt.ISO8601Format(),
        ]
        if let calendar = try MeetingCalendarSync.fetch(meetingId: meeting.id, in: db) {
            payload.merge(calendar.payload) { _, canonical in canonical }
        } else if let uid = meeting.calendarEventIcalUid, let recurrenceId = meeting.calendarEventRecurrenceId {
            payload["icalUid"] = uid
            payload["recurrenceId"] = recurrenceId
            if let event = try CalendarEventRecord.fetch(
                key: CalendarEventKey(icalUid: uid, recurrenceId: recurrenceId), in: db
            ) {
                payload["calendarEvent"] = [
                    "start": event.start.ISO8601Format(),
                    "end": event.end.ISO8601Format(),
                    "is_all_day": event.isAllDay,
                    "attendees": event.attendees.map {
                        ["email": $0.email, "display_name": $0.displayName as Any? ?? NSNull()]
                    },
                ]
            }
        }
        if action == .create { payload["createdAt"] = meeting.createdAt.ISO8601Format() }
        return try operation(entity: .meeting, action: action, id: meeting.id, payload: payload)
    }

    static func summaryOperation(_ summary: SummaryContent, action: SyncAction) throws -> SyncOperationDraft {
        try operation(
            entity: .summary,
            action: action,
            id: summary.meetingId,
            payload: action == .delete ? [:] : [
                "title": summary.title,
                "document": summary.document,
                "createdAt": summary.createdAt.ISO8601Format(),
            ]
        )
    }

    static func screenshotOperation(
        _ screenshot: MeetingScreenshotRecord,
        action: SyncAction,
        contentHash: String? = nil
    ) throws -> SyncOperationDraft {
        guard let hash = contentHash ?? screenshot.contentHash else { throw SyncTransactionQueueError.invalidReceipt }
        let payload = FileOperationPayload(
            name: "capture.\(screenshot.mimeType.split(separator: "/").last ?? "bin")",
            checksum: "SHA-256:" + hash,
            metadata: FileMetadata(
                source: .screenshot,
                width: screenshot.pixelWidth,
                height: screenshot.pixelHeight,
                ocrText: screenshot.ocrText,
                caption: screenshot.caption
            )
        )
        return try SyncOperationDraft(
            entity: .file,
            action: action,
            entityId: screenshot.originalFileId,
            payloadJSON: SyncJSON.encoder.encode(payload)
        )
    }

    static func fileOperation(_ file: FileRecord, in db: Database) throws -> SyncOperationDraft {
        guard let text = try TextContentAccess.fileText(fileId: file.id, in: db) else { throw TextContentError.incomplete }
        return try SyncOperationDraft(
            entity: .file,
            action: .upsert,
            entityId: file.id,
            payloadJSON: SyncJSON.encoder.encode(FileOperationPayload(
                name: file.name,
                checksum: file.checksum,
                metadata: FileMetadata(
                    source: file.metadata.source,
                    width: file.metadata.width,
                    height: file.metadata.height,
                    ocrText: text.ocrText,
                    caption: text.caption
                )
            ))
        )
    }

    static func meetingAttachmentOperation(_ screenshot: MeetingScreenshotRecord) throws -> SyncOperationDraft {
        try meetingAttachmentOperation(MeetingAttachmentRecord(
            id: screenshot.id,
            meetingId: screenshot.meetingId,
            fileId: screenshot.originalFileId,
            capturedAt: screenshot.capturedAt,
            sessionId: screenshot.sessionId,
            createdAt: screenshot.capturedAt
        ))
    }

    static func meetingAttachmentOperation(_ link: MeetingAttachmentRecord) throws -> SyncOperationDraft {
        try operation(entity: .meetingAttachment, action: .upsert, id: link.id, payload: [
            "meetingId": json(link.meetingId), "fileId": json(link.fileId), "capturedAt": json(link.capturedAt),
            "sessionId": json(link.sessionId), "createdAt": link.createdAt.ISO8601Format(),
        ])
    }

    private static func enqueueFiles(workspaceId: UUID, connectionId: UUID, markerId: UUID, restoring: Bool, dbQueue: DatabaseQueue) async throws {
        var lastId: UUID?
        while true {
            let cursor = lastId
            let file = try await dbQueue.write { db -> FileRecord? in
                guard try canContinue(markerId: markerId, workspaceId: workspaceId, in: db) else { return nil }
                let file = try FileRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM files WHERE workspace_id = ? AND (? IS NULL OR id > ?) ORDER BY id LIMIT 1",
                    arguments: [workspaceId, cursor, cursor]
                )
                guard let file, let reference = file.localReference else { return nil }
                let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
                let operation = try fileOperation(file, in: db)
                try SyncTransactionRecorder.record(
                    workspaceId: workspaceId,
                    operations: [operation],
                    screenshotAttachments: [operation.id: SyncScreenshotAttachmentReference(
                        mimeType: file.contentType,
                        source: source
                    )],
                    allowAfterReset: restoring,
                    connectionIdOverride: connectionId,
                    in: db
                )
                return file
            }
            guard let file else { break }
            lastId = file.id
        }
    }

    static func projectOperation(_ project: ProjectRecord, action: SyncAction) throws -> SyncOperationDraft {
        guard project.description.utf16.count <= 20000 else {
            throw ProjectWorkspaceError.descriptionTooLong
        }
        var payload: [String: Any] = [
            "parentProjectId": json(project.parentProjectId),
            "name": project.name,
            "description": project.description,
            "projectType": json(project.projectType?.rawValue),
            "icon": json(project.parentProjectId == nil ? project.icon : nil),
            "color": json(project.parentProjectId == nil ? project.color : nil),
        ]
        if action == .create { payload["createdAt"] = project.createdAt.ISO8601Format() }
        return try operation(entity: .project, action: action, id: project.id, payload: payload)
    }

    static func workspaceOperation(_ workspace: WorkspaceRecord, action: SyncAction) throws -> SyncOperationDraft {
        var payload: [String: Any] = ["name": workspace.name, "icon": json(workspace.icon), "color": json(workspace.color)]
        if action == .create {
            guard let organizationId = workspace.organizationId else { throw SyncTransactionQueueError.invalidReceipt }
            payload["organizationId"] = json(organizationId)
            payload["createdAt"] = workspace.createdAt.ISO8601Format()
        }
        return try operation(entity: .workspace, action: action, id: workspace.id, payload: payload)
    }

    private static func operation(
        entity: SyncEntity,
        action: SyncAction,
        id: UUID,
        payload: [String: Any]
    ) throws -> SyncOperationDraft {
        try SyncOperationDraft(
            entity: entity,
            action: action,
            entityId: id,
            payloadJSON: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        )
    }

    private static func json(_ value: UUID?) -> Any { value?.uuidString.lowercased() ?? NSNull() }
    private static func json(_ value: Date?) -> Any { value?.ISO8601Format() ?? NSNull() }
    private static func json(_ value: String?) -> Any { value ?? NSNull() }
    private static func json(_ value: Double?) -> Any { value ?? NSNull() }
    static func enqueueContents(_ items: [WorkspaceRelocation.Item], workspaceId: UUID, in db: Database) throws {
        let projects = try items.filter { $0.entity == .project }.map { item in
            guard let project = try ProjectRecord.fetchOne(db, key: item.id) else { throw LocalWorkspaceImportError.changed }
            return project
        }.sorted { $0.parentProjectId == nil && $1.parentProjectId != nil }
        try SyncTransactionRecorder.recordBatches(workspaceId: workspaceId, operations: projects.map {
            try Self.projectOperation($0, action: .create)
        }, in: db)
        for item in items where item.entity == .meeting {
            guard let meeting = try MeetingRecord.fetchOne(db, key: item.id) else { throw LocalWorkspaceImportError.changed }
            try TextContentAccess.requireComplete(entity: .summary, id: meeting.id, in: db)
            try TextContentAccess.requireComplete(entity: .transcript, id: meeting.id, in: db)
            try SyncTransactionRecorder.record(workspaceId: workspaceId, operations: [
                Self.meetingOperation(meeting, action: .create, in: db),
            ], in: db)
            if let summary = try SummaryContent.fetchOne(db, key: meeting.id) {
                try SyncTransactionRecorder.record(workspaceId: workspaceId, operations: [
                    Self.summaryOperation(summary, action: .upsert),
                ], in: db)
            }
            if var transcript = try TranscriptRecord.current(meeting.id, in: db) {
                transcript.version = nil
                transcript.syncRevision = nil
                try TranscriptRecord(meetingId: meeting.id, info: transcript).save(db)
                try TranscriptRecord.enqueueSnapshot(meetingId: meeting.id, info: transcript, in: db)
            }
        }
        for item in items where item.entity == .file {
            guard let file = try FileRecord.fetchOne(db, key: item.id), let reference = file.localReference else {
                throw ScreenshotContentError.unavailable
            }
            let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
            let operation = try Self.fileOperation(file, in: db)
            try SyncTransactionRecorder.record(workspaceId: workspaceId, operations: [operation], screenshotAttachments: [
                operation.id: .init(mimeType: file.contentType, source: source),
            ], in: db)
        }
        for item in items where item.entity == .meeting {
            let attachments = try MeetingAttachmentRecord.filter(Column("meetingId") == item.id).fetchCursor(db)
            while let attachment = try attachments.next() {
                try SyncTransactionRecorder.record(workspaceId: workspaceId, operations: [
                    Self.meetingAttachmentOperation(attachment),
                ], in: db)
            }
            let archives = try RecordingArchiveRecord.filter(Column("meetingId") == item.id).fetchCursor(db)
            while var archive = try archives.next() {
                guard let target = try WorkspaceRecord.fetchOne(db, key: workspaceId) else { throw LocalWorkspaceImportError.changed }
                let prepared = try SyncJSON.decoder.decode([String: RecordingArchiveEncoder.Prepared].self, from: Data(archive.preparedJSON.utf8))
                guard !prepared.isEmpty else { throw LocalWorkspaceImportError.unavailable }
                archive.connectionId = target.accountConnectionId
                archive.number = nil
                archive.audioJSON = "{}"
                archive.verifiedAt = nil
                archive.state = "syncing"
                try archive.update(db)
                for (source, file) in prepared.sorted(by: { $0.key < $1.key }) {
                    let payload = RecordingArchiveService.Commit(source: source, checksum: file.checksum, manifest: file.manifest)
                    try SyncTransactionRecorder.record(workspaceId: workspaceId, operations: [
                        SyncOperationDraft(
                            entity: .recording,
                            action: .upsert,
                            entityId: archive.sessionId,
                            payloadJSON: SyncJSON.encoder.encode(payload)
                        ),
                    ], in: db)
                }
            }
        }
    }
}
