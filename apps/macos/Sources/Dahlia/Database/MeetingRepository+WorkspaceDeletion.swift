import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingRepository {
    /// Moves durable content and removes only the empty source, in one transaction. Audio stays in place.
    nonisolated func transferAndDeleteWorkspace(id: UUID, destinationID: UUID) async throws {
        try await DocumentEditorModel.finishLocalSaves(dbQueue: dbQueue)
        let queue = dbQueue
        try await Task.detached(priority: .userInitiated) {
            let lockedSource = try queue.read { db in
                guard let source = try WorkspaceRecord.fetchOne(db, key: id) else {
                    throw ProjectWorkspaceError.invalidMoveDestination
                }
                return source
            }
            let transfer = {
                try queue.write { db in
                    guard id != destinationID,
                          let source = try WorkspaceRecord.fetchOne(db, key: id),
                          try WorkspaceRecord.exists(db, key: destinationID),
                          source.path == lockedSource.path
                    else { throw ProjectWorkspaceError.invalidMoveDestination }
                    for workspaceID in [id, destinationID] {
                        guard try !RecordingSessionRecord.hasActiveRecording(workspaceId: workspaceID, in: db)
                        else { throw ProjectWorkspaceError.workspaceBusy }
                    }

                    // Keep both hierarchies intact when root names collide; never merge or overwrite Projects.
                    let destinationNames = try Set(ProjectRecord.filter(Column("workspace_id") == destinationID)
                        .filter(Column("parentProjectId") == nil).fetchAll(db).map(\.nameKey))
                    let roots = try ProjectRecord.filter(Column("workspace_id") == id)
                        .filter(Column("parentProjectId") == nil).order(Column("id")).fetchAll(db)
                    var names = destinationNames.union(roots.map(\.nameKey))
                    for var root in roots where destinationNames.contains(root.nameKey) {
                        let originalName = root.name
                        var suffix = 2
                        while names.contains(root.nameKey) {
                            root.name = DahliaProjectName.migrationSafeName(originalName, suffix: " (\(suffix))")
                            suffix += 1
                        }
                        names.insert(root.nameKey)
                        if root.name != originalName {
                            root.revision += 1
                            try root.update(db)
                            let descendants = try ProjectRecord.hierarchy(projectId: root.id, workspaceId: id, in: db).dropFirst().map(\.id)
                            try ProjectRecord.incrementRevisions(Set(descendants), in: db)
                        }
                    }

                    var instructionNames = try Set(InstructionRecord.filter(Column("workspace_id") == destinationID).fetchAll(db).map(\.name))
                    for var instruction in try InstructionRecord.filter(Column("workspace_id") == id).order(Column("id")).fetchAll(db) {
                        let originalName = instruction.name
                        var suffix = 2
                        while instructionNames.contains(instruction.name) {
                            instruction.name = "\(originalName) (\(suffix))"
                            suffix += 1
                        }
                        instructionNames.insert(instruction.name)
                        instruction.workspaceId = destinationID
                        try instruction.update(db)
                    }

                    // Existing exports stay in the source folder; their relative URLs must not resolve under the destination.
                    try db.execute(sql: """
                    DELETE FROM summary_exports WHERE type = ?
                    AND meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)
                    """, arguments: [SummaryExportType.workspace, id])
                    try Self.moveContent(from: id, to: destinationID, in: db)
                    // Meeting Notes follow their Meeting via ON UPDATE CASCADE; include independent Documents and recoveries too.
                    for table in ["documents", "document_private_copies", "document_local_archives"] {
                        try db.execute(sql: "UPDATE \(table) SET workspace_id = ? WHERE workspace_id = ?", arguments: [destinationID, id])
                    }
                    _ = try WorkspaceRecord.deleteOne(db, key: id)
                }
            }
            guard let workspaceURL = lockedSource.url,
                  FileManager.default.fileExists(atPath: workspaceURL.path) else { return try transfer() }
            do {
                try DahliaWorkspaceMutationLock.withLock(workspaceURL: workspaceURL, workspaceID: id, operation: transfer)
            } catch is DahliaWorkspaceMutationLockError {
                throw ProjectWorkspaceError.workspaceBusy
            }
        }.value
    }

    /// Moves every Project, Meeting, and file to the destination. The caller owns validation and the transaction.
    private nonisolated static func moveContent(from source: UUID, to destination: UUID, in db: Database) throws {
        // The relocation scope lets these rows change Workspace; parents move before their children.
        try db.execute(
            sql: "INSERT OR IGNORE INTO workspace_relocation_scope(source_workspace_id, destination_workspace_id) VALUES (?, ?)",
            arguments: [source, destination]
        )
        try db.execute(sql: """
        UPDATE projects SET workspace_id = ? WHERE workspace_id = ? AND parentProjectId IS NULL;
        UPDATE projects SET workspace_id = ? WHERE workspace_id = ?;
        UPDATE recording_audio_files SET original_workspace_path = (SELECT path FROM workspaces WHERE id = ?)
        WHERE storageLocation = 'vault' AND original_workspace_path IS NULL AND recordingSessionId IN (
            SELECT s.id FROM recording_sessions s JOIN meetings m ON m.id = s.meetingId WHERE m.workspace_id = ?);
        UPDATE recording_archives SET workspace_id = ? WHERE meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?);
        UPDATE document_local_archives SET workspace_id = ? WHERE workspace_id = ? AND meetingId IS NOT NULL;
        UPDATE meetings SET workspace_id = ?, projectId = projectId WHERE workspace_id = ?;
        UPDATE files SET workspace_id = ?, metadata = metadata WHERE workspace_id = ?;
        DELETE FROM workspace_relocation_scope;
        """, arguments: [
            destination, source, destination, source, source, source, destination, source,
            destination, source, destination, source, destination, source,
        ])
        // Former Server content may never have been downloaded. Keep that fact when the source is deleted.
        for table in ["sync_content_state", "sync_entity_state"] {
            try db.execute(
                sql: "UPDATE \(table) SET workspace_id = ? WHERE workspace_id = ? AND entity <> 'workspace'",
                arguments: [destination, source]
            )
        }
    }
}
