import Foundation
import GRDB
import Synchronization

/// Shared by archive and file transport; one of four permits is reserved for interactive work.
actor SyncTransferSlots {
    private struct Entry: Sendable { weak var value: SyncTransferSlots? }
    private static let registry = Mutex<[ObjectIdentifier: Entry]>([:])
    private let database: DatabaseQueue
    private var active: [UUID: Bool] = [:]
    private struct Waiter {
        let id: UUID
        let background: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiting: [Waiter] = []

    private init(database: DatabaseQueue) { self.database = database }

    nonisolated static func shared(dbQueue: DatabaseQueue) -> SyncTransferSlots {
        registry.withLock { values in
            values = values.filter { $0.value.value != nil }
            let key = ObjectIdentifier(dbQueue)
            if let value = values[key]?.value { return value }
            let value = SyncTransferSlots(database: dbQueue)
            values[key] = Entry(value: value)
            return value
        }
    }

    func perform<T: Sendable>(background: Bool, operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiter(id: id, background: background, continuation: continuation))
                admit()
            }
        } onCancel: { Task { await self.cancel(id) } }
        defer {
            active[id] = nil
            admit()
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func admit() {
        while active.count < 4 {
            let backgroundAvailable = active.values.filter(\.self).count < 3
            let foregroundIndex = waiting.firstIndex(where: { !$0.background })
            let nextIndex = foregroundIndex ?? (backgroundAvailable ? waiting.indices.first : nil)
            guard let index = nextIndex else { return }
            let waiter = waiting.remove(at: index)
            active[waiter.id] = waiter.background
            waiter.continuation.resume()
        }
    }
}
