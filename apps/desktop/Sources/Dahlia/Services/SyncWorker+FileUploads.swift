import DahliaRuntimeSupport
import DahliaServerAPI
import Foundation
import GRDB
import OpenAPIRuntime

private struct FileUploadResponse: Decodable {
    let id: UUID
    let workspaceId: UUID
    let size: Int
    let checksum: String
}

extension SyncWorker {
    struct PendingFileUpload {
        let upload: SyncFileUpload
        let task: Task<Void, Error>
        let observation: AnyDatabaseCancellable
        var finishedAt: Date?
    }

    func prepareFileUploads(for transaction: SyncQueuedTransaction, origin: URL) async throws {
        let candidates = try await dbQueue.read { db in
            try SyncTransactionQueue.fileUploads(for: transaction, origin: origin, in: db)
        }
        try Task.checkCancellation()
        guard !fileUploadsStopped else { throw CancellationError() }
        fileUploadCandidates = candidates
        let ids = Set(candidates.map(\.operation.id))
        for (id, pending) in fileUploads where !ids.contains(id) {
            pending.task.cancel()
            if pending.finishedAt != nil { fileUploads.removeValue(forKey: id) }
        }
        startFileUploads()
    }

    /// Acquire an upload slot before loading the immutable original, including demand uploads.
    func stageFileUpload(_ upload: SyncFileUpload) async throws {
        let id = upload.operation.id
        if let finishedAt = fileUploads[id]?.finishedAt, Date.now.timeIntervalSince(finishedAt) > 300 {
            fileUploads.removeValue(forKey: id)
        }
        fileUploadCandidates.removeAll { $0.operation.id == id }
        fileUploadCandidates.insert(upload, at: 0)
        defer {
            fileUploadCandidates.removeAll { $0.operation.id == id }
            if fileUploads[id]?.finishedAt != nil { fileUploads.removeValue(forKey: id) }
        }
        while fileUploads[id] == nil {
            try Task.checkCancellation()
            guard !fileUploadsStopped else { throw CancellationError() }
            startFileUploads()
            if fileUploads[id] != nil { break }
            guard let running = fileUploads.values.first(where: { $0.finishedAt == nil }) else { throw CancellationError() }
            _ = await running.task.result
        }
        guard let pending = fileUploads[id], pending.upload == upload else { throw CancellationError() }
        try await withTaskCancellationHandler {
            try await pending.task.value
        } onCancel: {
            pending.task.cancel()
        }
        try Task.checkCancellation()
        guard try await dbQueue.read({ try upload.isCurrent(in: $0) }) else { throw CancellationError() }
    }

    private func startFileUploads() {
        guard !fileUploadsStopped else { return }
        for upload in fileUploadCandidates {
            guard fileUploads.values.filter({ $0.finishedAt == nil }).count < 4 else { return }
            let id = upload.operation.id
            guard fileUploads[id] == nil,
                  !fileUploads.values.contains(where: { $0.finishedAt == nil && $0.upload.operation.entityId == upload.operation.entityId })
            else { continue }
            let task = Task {
                defer { fileUploadFinished(id) }
                do {
                    try await uploadFile(upload)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
            let observation = ValueObservation.tracking { db in
                try upload.isCurrent(in: db)
            }.removeDuplicates().start(
                in: dbQueue,
                scheduling: .async(onQueue: .global(qos: .utility)),
                onError: { _ in task.cancel() },
                onChange: { current in if !current { task.cancel() } }
            )
            fileUploads[id] = PendingFileUpload(upload: upload, task: task, observation: observation)
        }
    }

    private func fileUploadFinished(_ id: UUID) {
        fileUploads[id]?.observation.cancel()
        fileUploads[id]?.finishedAt = .now
        if !fileUploadCandidates.contains(where: { $0.operation.id == id }) { fileUploads.removeValue(forKey: id) }
        startFileUploads()
    }

    func releaseFileUploads(transactionId: UUID) {
        fileUploadCandidates.removeAll { $0.transactionId == transactionId }
        for (id, pending) in fileUploads where pending.upload.transactionId == transactionId {
            pending.task.cancel()
            if pending.finishedAt != nil { fileUploads.removeValue(forKey: id) }
        }
    }

    func cancelFileUploads() {
        fileUploadsStopped = true
        fileUploadCandidates.removeAll()
        for pending in fileUploads.values {
            pending.task.cancel()
        }
    }

    func finishFileUploads() async {
        cancelFileUploads()
        let pending = Array(fileUploads.values)
        for upload in pending {
            _ = await upload.task.result
            upload.observation.cancel()
        }
        fileUploads.removeAll()
    }

    private func uploadFile(_ upload: SyncFileUpload) async throws {
        try Task.checkCancellation()
        guard try await dbQueue.read({ try upload.isCurrent(in: $0) }) else { throw CancellationError() }
        guard let attachment = try await SyncTransactionQueue.screenshotAttachment(operationId: upload.operation.id, dbQueue: dbQueue) else { return }
        try Task.checkCancellation()
        guard let data = upload.operation.payloadJSON else { throw SyncTransactionQueueError.invalidReceipt }
        let payload = try SyncJSON.decoder.decode(FileOperationPayload.self, from: data)
        typealias Reservation = Operations.ReserveFileUpload.Input.Body.JsonPayload
        guard let source = Reservation.MetadataPayload.SourcePayload(rawValue: payload.metadata.source.rawValue) else {
            throw SyncTransactionQueueError.invalidReceipt
        }
        let reservation = Reservation(
            id: upload.operation.entityId.uuidString.lowercased(), workspaceId: upload.workspaceId.uuidString.lowercased(),
            name: payload.name, contentType: attachment.mimeType,
            metadata: .init(source: source, width: payload.metadata.width, height: payload.metadata.height)
        )
        _ = try await apiClient.data(origin: upload.origin, connectionId: upload.connectionId) {
            let response = try await $0.reserveFileUpload(body: .json(reservation))
            if case let .created(value) = response { return try value.body.json }
            return try response.ok.body.json
        }
        try Task.checkCancellation()
        let response = try await apiClient.data(origin: upload.origin, connectionId: upload.connectionId) {
            let response = try await $0.putFileContent(
                path: .init(fileId: upload.operation.entityId.uuidString.lowercased()),
                headers: .init(contentLength: String(attachment.bytes.count)), body: .binary(HTTPBody(attachment.bytes))
            )
            if case let .created(value) = response { return try value.body.json }
            return try response.ok.body.json
        }
        let uploaded = try SyncJSON.decoder.decode(FileUploadResponse.self, from: response)
        guard uploaded.id == upload.operation.entityId, uploaded.workspaceId == upload.workspaceId,
              uploaded.size == attachment.bytes.count, uploaded.checksum == "SHA-256:" + attachment.sha256,
              uploaded.checksum == payload.checksum else { throw SyncTransactionQueueError.invalidReceipt }
    }
}
