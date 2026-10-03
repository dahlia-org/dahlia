import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

enum SyncInitialSnapshotBuilder {
    private static let serverImageAnalysisContentTypes: Set = [
        "image/png", "image/jpeg", "image/webp", "image/gif", "image/tiff",
    ]

    static func enqueuePending(
        dbQueue: DatabaseQueue,
        screenshotContent: ScreenshotContentProvider = .shared,
        replaceServerImageAnalysisWorkspaceId: UUID? = nil,
        onFailure: @Sendable (any Error) throws -> Void = { throw $0 }
    ) async throws {
        try await SyncInitialProgress.enqueuePending(
            dbQueue: dbQueue,
            screenshotContent: screenshotContent,
            replaceImages: replaceServerImageAnalysisWorkspaceId,
            onFailure: onFailure
        )
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
                    workspaceId: workspaceId, background: true,
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

    static func fileOperation(
        _ file: FileRecord,
        replaceServerImageAnalysis: Bool = false,
        in db: Database
    ) throws -> SyncOperationDraft {
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
                ),
                imageAnalysis: replaceServerImageAnalysis
                    && file.metadata.source == .screenshot
                    && Self.serverImageAnalysisContentTypes.contains(file.contentType)
                    ? "replace" : nil
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
        var payload: [String: Any] = try [
            "name": workspace.name,
            "icon": json(workspace.icon),
            "color": json(workspace.color),
            "generationSettings": JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.generationSettings)),
        ]
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
    static func enqueueContents(
        _ items: [WorkspaceRelocation.Item],
        workspaceId: UUID,
        replaceServerImageAnalysis: Bool = false,
        existing: SyncResetSnapshot = .init(ids: [:]),
        in db: Database
    ) throws {
        let projects = try items.filter { $0.entity == .project && !existing.projects.contains($0.id) }.map { item in
            guard let project = try ProjectRecord.fetchOne(db, key: item.id) else { throw LocalWorkspaceImportError.changed }
            return project
        }.sorted { $0.parentProjectId == nil && $1.parentProjectId != nil }
        try SyncTransactionRecorder.recordBatches(workspaceId: workspaceId, background: true, operations: projects.map {
            try Self.projectOperation($0, action: .create)
        }, in: db)
        for item in items where item.entity == .meeting {
            try enqueueMeetingContents(meetingId: item.id, workspaceId: workspaceId, existing: existing, in: db)
        }
        for item in items where item.entity == .file && !existing.files.contains(item.id) {
            guard let file = try FileRecord.fetchOne(db, key: item.id), let reference = file.localReference else {
                throw ScreenshotContentError.unavailable
            }
            let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
            let operation = try Self.fileOperation(
                file,
                replaceServerImageAnalysis: replaceServerImageAnalysis,
                in: db
            )
            try SyncTransactionRecorder.record(workspaceId: workspaceId, background: true, operations: [operation], screenshotAttachments: [
                operation.id: .init(mimeType: file.contentType, source: source),
            ], in: db)
        }
        for item in items where item.entity == .meeting {
            for attachment in try MeetingAttachmentRecord.filter(Column("meetingId") == item.id).fetchAll(db)
                where !existing.screenshots.contains(attachment.id) {
                try SyncTransactionRecorder.record(
                    workspaceId: workspaceId,
                    background: true,
                    operations: [meetingAttachmentOperation(attachment)],
                    in: db
                )
            }
        }
        try enqueueRecordingContents(items, workspaceId: workspaceId, existing: existing, in: db)
    }

    static func enqueueRecordingContents(
        _ items: [WorkspaceRelocation.Item],
        workspaceId: UUID,
        existing: SyncResetSnapshot,
        in db: Database
    ) throws {
        for item in items where item.entity == .meeting {
            guard let target = try WorkspaceRecord.fetchOne(db, key: workspaceId),
                  let connectionId = target.accountConnectionId else { throw LocalWorkspaceImportError.changed }
            try db.execute(sql: """
            INSERT OR IGNORE INTO recording_archives(sessionId, meetingId, workspace_id, connectionId)
            SELECT sessions.id, sessions.meetingId, ?, ?
            FROM recording_sessions AS sessions
            WHERE sessions.meetingId = ?
              AND sessions.transcriptionMode = ?
              AND sessions.batchDiscardedAt IS NULL
              AND EXISTS (
                  SELECT 1 FROM recording_audio_segments AS segments
                  WHERE segments.recordingSessionId = sessions.id
                    AND segments.state NOT IN (?, ?)
                    AND segments.purgedAt IS NULL
              )
            """, arguments: [
                workspaceId,
                connectionId,
                item.id,
                TranscriptionMode.batch.rawValue,
                RecordingAudioSegmentState.purged.rawValue,
                RecordingAudioSegmentState.failed.rawValue,
            ])
            let archives = try RecordingArchiveRecord.filter(Column("meetingId") == item.id).fetchCursor(db)
            while var archive = try archives.next() {
                let prepared = try SyncJSON.decoder.decode([String: RecordingArchiveEncoder.Prepared].self, from: Data(archive.preparedJSON.utf8))
                if existing.recordings.contains(archive.sessionId) {
                    try enqueueMissingRecordingSources(archive, prepared: prepared, workspaceId: workspaceId, in: db)
                    continue
                }
                let hasRetainedSegments = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM recording_audio_segments
                    WHERE recordingSessionId = ?
                      AND state NOT IN (?, ?)
                      AND purgedAt IS NULL
                )
                """, arguments: [
                    archive.sessionId,
                    RecordingAudioSegmentState.purged.rawValue,
                    RecordingAudioSegmentState.failed.rawValue,
                ]) ?? false
                guard !prepared.isEmpty || hasRetainedSegments else {
                    if archive.audioJSON == "{}" {
                        archive.state = "expired"
                        archive.retryAt = nil
                        archive.failureCode = nil
                        try archive.update(db)
                    }
                    continue
                }
                if prepared.isEmpty {
                    let hasUnarchivableSegments = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM recording_audio_segments
                        WHERE recordingSessionId = ?
                          AND state NOT IN (?, ?, ?)
                    )
                    """, arguments: [
                        archive.sessionId,
                        RecordingAudioSegmentState.ready.rawValue,
                        RecordingAudioSegmentState.purgePending.rawValue,
                        RecordingAudioSegmentState.purged.rawValue,
                    ]) ?? false
                    guard !hasUnarchivableSegments else { throw LocalWorkspaceImportError.unavailable }
                }
                archive.connectionId = connectionId
                archive.number = nil
                archive.audioJSON = "{}"
                archive.verifiedAt = nil
                archive.state = prepared.isEmpty ? "pending" : "syncing"
                archive.retryAt = nil
                archive.failureCode = nil
                try archive.update(db)
                guard !prepared.isEmpty else { continue }
                for (source, file) in prepared.sorted(by: { $0.key < $1.key }) {
                    let payload = RecordingArchiveService.Commit(source: source, checksum: file.checksum, manifest: file.manifest)
                    try SyncTransactionRecorder.record(workspaceId: workspaceId, background: true, operations: [
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

    private static func enqueueMeetingContents(
        meetingId: UUID,
        workspaceId: UUID,
        existing: SyncResetSnapshot,
        in db: Database
    ) throws {
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { throw LocalWorkspaceImportError.changed }
        if !existing.meetings.contains(meeting.id) {
            try SyncTransactionRecorder.record(workspaceId: workspaceId, background: true, operations: [
                Self.meetingOperation(meeting, action: .create, in: db),
            ], in: db)
        }
        if !existing.summaries.contains(meeting.id) {
            try TextContentAccess.requireComplete(entity: .summary, id: meeting.id, in: db)
            if let summary = try SummaryContent.fetchOne(db, key: meeting.id) {
                try SyncTransactionRecorder.record(workspaceId: workspaceId, background: true, operations: [
                    Self.summaryOperation(summary, action: .upsert),
                ], in: db)
            }
        }
        if !existing.transcripts.contains(meeting.id) {
            try TextContentAccess.requireComplete(entity: .transcript, id: meeting.id, in: db)
            if var transcript = try TranscriptRecord.current(meeting.id, in: db) {
                transcript.version = nil
                transcript.syncRevision = nil
                try TranscriptRecord(meetingId: meeting.id, info: transcript).save(db)
                try TranscriptRecord.enqueueSnapshot(meetingId: meeting.id, info: transcript, in: db)
            }
        }
    }

    private static func enqueueMissingRecordingSources(
        _ archive: RecordingArchiveRecord,
        prepared: [String: RecordingArchiveEncoder.Prepared],
        workspaceId: UUID,
        in db: Database
    ) throws {
        let canonical = try archive.audio
        // Reconnection adopts existing Server sources. Only still-missing sources are submitted;
        // differing local originals/preparations remain available without overwriting Server audio.
        for (source, file) in prepared.sorted(by: { $0.key < $1.key }) where canonical[source] == nil {
            try SyncTransactionRecorder.record(workspaceId: workspaceId, background: true, operations: [
                SyncOperationDraft(
                    entity: .recording,
                    action: .upsert,
                    entityId: archive.sessionId,
                    payloadJSON: SyncJSON.encoder.encode(RecordingArchiveService.Commit(
                        source: source,
                        checksum: file.checksum,
                        manifest: file.manifest
                    ))
                ),
            ], in: db)
        }
    }

}
