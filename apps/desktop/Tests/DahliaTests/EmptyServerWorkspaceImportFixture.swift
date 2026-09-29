#if canImport(Testing)
    import Foundation
    import GRDB
    @testable import Dahlia

    extension MeetingRepository {
        /// Stage an empty Server snapshot and exercise the shared import commit, without a live Server.
        nonisolated func importIntoEmptyServerWorkspace(
            id: UUID,
            connectionID: UUID,
            serverWorkspace: CloudWorkspaceRecord,
            transferFence: WorkspaceTransferFence,
            replaceServerImageAnalysis: Bool = false,
            screenshotContent: ScreenshotContentProvider = .shared
        ) async throws -> WorkspaceRecord? {
            guard serverWorkspace.workspaceId == id, serverWorkspace.connectionId == connectionID else {
                throw LocalWorkspaceImportError.unavailable
            }
            try await dbQueue.read { db in
                try LocalWorkspaceImport.validate(sourceId: id, destination: serverWorkspace, reconnectExisting: true, in: db)
            }
            try await DocumentPersistence(dbQueue: dbQueue).prepareAccountTransfer(workspaceID: id)
            let files = try await screenshotContent.prepareAccountTransfer(workspaceId: id, connectionId: connectionID, dbQueue: dbQueue)
            var workspace = WorkspaceRecord(
                id: id,
                path: nil,
                name: serverWorkspace.name,
                createdAt: serverWorkspace.createdAt,
                lastOpenedAt: .distantPast
            )
            workspace.organizationId = serverWorkspace.organizationId
            let draft = try SyncInitialSnapshotBuilder.workspaceOperation(workspace, action: .create)
            let store = try SyncSnapshotStore()
            try await store.merge([.init(
                sequence: 0,
                entity: .workspace,
                entityId: id,
                action: "upsert",
                revision: serverWorkspace.revision,
                record: SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: draft.payloadJSON!)
            )])
            let snapshot = try await WorkspaceReconnectionSnapshot(store: store, cursor: "empty-server", ids: store.resetSnapshot(), projects: [])
            return try await dbQueue.write { db in
                guard try transferFence.isCurrent(in: db) else { throw LocalWorkspaceImportError.changed }
                let result = try LocalWorkspaceImport.commit(
                    sourceId: id, destination: serverWorkspace, snapshot: snapshot.ids, files: files,
                    backupPath: "/tmp/test-import-backup.dahlia", replaceServerImageAnalysis: replaceServerImageAnalysis,
                    reconnection: snapshot, in: db
                )
                try transferFence.release(in: db)
                return result
            }
        }
    }
#endif
