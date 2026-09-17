import DahliaRuntimeSupport
import Foundation

private let retryableSyncTransportCodes: Set<URLError.Code> = [
    .timedOut,
    .cannotFindHost,
    .cannotConnectToHost,
    .networkConnectionLost,
    .dnsLookupFailed,
    .notConnectedToInternet,
    .internationalRoamingOff,
    .callIsActive,
    .dataNotAllowed,
    .secureConnectionFailed,
    .clientCertificateRejected,
    .clientCertificateRequired,
    .cannotLoadFromNetwork,
    .resourceUnavailable,
    .backgroundSessionWasDisconnected,
]

extension SyncWorker {
    nonisolated static func localQueueFailureDisposition(_ error: any Error) -> LocalQueueFailureDisposition {
        if error is CancellationError { return .ignore }
        if let error = error as? URLError {
            if error.code == .cancelled { return .ignore }
            if retryableSyncTransportCodes.contains(error.code) { return .retry }
        }
        return .block(localFailureCode(error))
    }

    nonisolated static func localFailureCode(_ error: any Error) -> String {
        if let error = error as? URLError { return localFailureCode(error) }
        if let error = error as? ScreenshotContentError { return localFailureCode(error) }
        if let error = error as? RecordingAudioStoreError { return localFailureCode(error) }
        if let error = error as? TextContentError { return "local_text_\(error.rawValue)" }
        if let error = error as? SyncTransactionQueueError {
            return switch error {
            case .invalidReceipt: "invalid_sync_receipt"
            case .pendingTransactions: "pending_sync_transactions"
            case .serverCopyExists: "server_copy_exists"
            case .readOnlyWorkspace: "read_only_workspace"
            }
        }
        if error is TypeID.Failure || error is DecodingError || error is EncodingError { return "invalid_sync_payload" }
        return "local_sync_failed"
    }

    private nonisolated static func localFailureCode(_ error: URLError) -> String {
        switch error.code {
        case .dataLengthExceedsMaximum: "invalid_sync_response_size"
        case .badServerResponse, .cannotDecodeContentData, .cannotDecodeRawData, .cannotParseResponse:
            "invalid_sync_response"
        case .badURL, .unsupportedURL: "invalid_sync_request"
        case .fileDoesNotExist: "local_file_unavailable"
        case .noPermissionsToReadFile: "local_file_authorization_required"
        default: "local_sync_failed"
        }
    }

    private nonisolated static func localFailureCode(_ error: ScreenshotContentError) -> String {
        switch error {
        case .unavailable: "local_file_unavailable"
        case .authorizationRequired: "local_file_authorization_required"
        case .deleted: "local_file_deleted"
        case .integrityFailure: "local_file_integrity_failure"
        }
    }

    private nonisolated static func localFailureCode(_ error: RecordingAudioStoreError) -> String {
        switch error {
        case .activeSession: "recording_audio_active_session"
        case .activeSegmentSafetyLimit: "recording_audio_safety_limit"
        case .ambiguousFiles: "recording_audio_ambiguous_files"
        case .diskSpaceLow: "recording_audio_disk_space_low"
        case .integrityMismatch: "recording_audio_integrity_mismatch"
        case .invalidPath: "recording_audio_invalid_path"
        case .invalidState: "recording_audio_invalid_state"
        case .missingSessionLease: "recording_audio_missing_session_lease"
        case .missingFile: "recording_audio_missing_file"
        case .storageUnavailable: "recording_audio_storage_unavailable"
        case .writeQueueOverflow: "recording_audio_write_queue_overflow"
        }
    }
}

struct SyncIncident: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case discovery
        case pull
    }

    let stage: Stage
    let status: Int?
    let code: String
    let occurredAt: Date

    init(stage: Stage, error: any Error, occurredAt: Date = .now) {
        self.stage = stage
        if let error = error as? SyncHTTPError {
            status = error.status
            code = error.code ?? "http_\(error.status)"
        } else {
            status = nil
            code = switch SyncWorker.localQueueFailureDisposition(error) {
            case .ignore: "cancelled"
            case .retry: "network"
            case let .block(code): code
            }
        }
        self.occurredAt = occurredAt
    }

    var jsonString: String? {
        guard let data = try? SyncJSON.encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    init?(jsonString: String?) {
        guard let jsonString,
              let value = try? SyncJSON.decoder.decode(Self.self, from: Data(jsonString.utf8)) else { return nil }
        self = value
    }
}

enum SyncServerLink {
    static func url(origin: String, workspaceId: UUID? = nil, target: SyncRecordTarget? = nil) -> URL? {
        guard let origin = URL(string: origin),
              ["https", "http"].contains(origin.scheme?.lowercased()),
              origin.host != nil else { return nil }
        let target = target ?? workspaceId.map { SyncRecordTarget(entity: .workspace, id: $0) }
        guard let target else { return origin }
        let route: (String, TypeID.Kind)? = switch target.entity {
        case .workspace: ("workspaces", .workspace)
        case .project: ("projects", .project)
        case .meeting, .summary, .transcript: ("meetings", .meeting)
        case .file: ("files", .file)
        case .meetingAttachment, .meetingEvent, .recording: nil
        }
        guard let route else {
            return workspaceId.map { origin.appending(path: "workspaces").appending(path: TypeID.encode($0, as: .workspace)) } ?? origin
        }
        return origin.appending(path: route.0).appending(path: TypeID.encode(target.id, as: route.1))
    }
}
