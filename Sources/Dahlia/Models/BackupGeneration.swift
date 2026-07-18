import Foundation

struct BackupMetadata: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    enum Reason: String, Codable, Sendable {
        case manual
        case beforeRestore
    }

    let formatVersion: Int
    let generationId: UUID
    let createdAt: Date
    let schemaVersion: Int
    let migrationIdentifier: String
    let appVersion: String
    let appBuild: String
    let reason: Reason
}

struct BackupGeneration: Identifiable, Equatable, Sendable {
    var id: URL { fileURL }

    let fileURL: URL
    let metadata: BackupMetadata?
    let fileSize: Int64
    let validationError: String?

    var isValid: Bool {
        metadata != nil && validationError == nil
    }
}

struct BackupPreflightItem: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case recording
        case awaitingConfirmation
        case processing
        case failed
    }

    var id: UUID { sessionId }

    let sessionId: UUID
    let meetingId: UUID
    let meetingName: String
    let startedAt: Date
    let state: State
    let failureMessage: String?
}
