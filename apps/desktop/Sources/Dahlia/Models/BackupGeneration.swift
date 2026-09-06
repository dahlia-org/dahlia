import Foundation

struct BackupMetadata: Codable, Equatable, Sendable {
    static let currentFormatVersion = 2

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
    let vaultId: UUID
    let vaultName: String
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
        case interrupted
        case failed
    }

    var id: UUID { sessionId }

    let sessionId: UUID
    let meetingId: UUID
    let vaultId: UUID
    let meetingName: String
    let startedAt: Date
    let state: State
    let failureMessage: String?
    let canTranscribe: Bool

    var canStartTranscription: Bool {
        guard canTranscribe else { return false }
        return switch state {
        case .awaitingConfirmation, .interrupted, .failed:
            true
        case .recording, .processing:
            false
        }
    }

    var isWorkInProgress: Bool {
        state == .recording || state == .processing
    }

    var canDiscard: Bool {
        !isWorkInProgress
    }

    var hasUnavailableAudio: Bool {
        !canTranscribe && canDiscard
    }

    var statusDescription: String {
        if hasUnavailableAudio { return L10n.batchRecordingAudioUnavailable }
        return switch state {
        case .recording: L10n.recordingInProgress
        case .awaitingConfirmation: L10n.awaitingTranscription
        case .processing: L10n.transcriptionInProgress
        case .interrupted: L10n.batchTranscriptionInterrupted
        case .failed: failureMessage ?? L10n.transcriptionFailed
        }
    }
}

struct VaultBackupRestoreRequest: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case overwrite
        case newVault
    }

    let sourceVaultId: UUID
    let targetVaultId: UUID
    let mode: Mode
    let name: String
}
