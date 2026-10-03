import DahliaRuntimeSupport
import Foundation

/// Local recovery metadata only. Never retain the response, values, or decoder's debug description.
struct SyncPayloadFailure: LocalizedError, Sendable {
    let operation: String
    let reason: String
    let field: String?

    init?(operation: String, error: any Error) {
        let context: DecodingError.Context?
        switch error {
        case let DecodingError.keyNotFound(key, value):
            reason = "missing_field"
            context = .init(codingPath: value.codingPath + [key], debugDescription: "")
        case let DecodingError.typeMismatch(_, value): reason = "wrong_type"
            context = value
        case let DecodingError.valueNotFound(_, value): reason = "missing_value"
            context = value
        case let DecodingError.dataCorrupted(value): reason = "invalid_value"
            context = value
        case is TypeID.Failure: reason = "invalid_public_id"
            context = nil
        default: return nil
        }
        self.operation = operation
        let fields: Set = [
            "items", "record", "sequence", "entity", "entityId", "id", "revision", "action", "cursor", "highWaterCursor", "hasMore",
            "workspaceId", "organizationId", "personalUserId", "projectId", "parentProjectId", "meetingId", "fileId", "sessionId",
            "createdAt", "updatedAt", "startedAt", "endedAt", "capturedAt", "recordingStartedAt", "generationSettings", "transcript",
            "metadata", "audio", "status", "contentCount", "contentPresent", "contentOmitted", "summaryRevision", "transcriptRevision",
        ]
        field = context?.codingPath.map { key in
            key.intValue != nil ? "[]" : fields.contains(key.stringValue) ? key.stringValue : "?"
        }.joined(separator: ".")
    }

    var diagnostic: String { [operation, reason, field].compactMap(\.self).joined(separator: " / ") }
    var errorDescription: String? { L10n.syncPayloadGuidance }
}
