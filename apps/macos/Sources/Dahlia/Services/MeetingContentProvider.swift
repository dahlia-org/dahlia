import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

/// Checks that meeting text is on this Mac before a reader uses it. Recording and finalized persistence never call or
/// wait for this. A body that is not here (one a Dahlia Server held alone) is unavailable.
struct MeetingContentProvider: Sendable {
    static let shared = Self()

    func withContent<T: Sendable>(
        meetingId: UUID,
        entities: Set<TextContentEntity> = [.summary, .transcript],
        dbQueue: any DatabaseWriter,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        for entity in entities {
            try await ensure(entity: entity, id: meetingId, dbQueue: dbQueue)
        }
        return try await operation()
    }

    func ensure(entity: TextContentEntity, id: UUID, dbQueue: any DatabaseWriter) async throws {
        try Task.checkCancellation()
        guard try await dbQueue.read({ (try? TextContentAccess.requireComplete(entity: entity, id: id, in: $0)) != nil }) else {
            throw TextContentError.unavailable
        }
    }
}
