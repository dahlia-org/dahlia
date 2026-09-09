import DahliaRuntimeSupport
import Foundation
import GRDB

enum RecordingProcessingMethod: String, Codable, CaseIterable, Identifiable {
    case transcript, cloudTranscription, audio
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .transcript: L10n.processingLocalTranscription
        case .cloudTranscription: L10n.processingCloudTranscription
        case .audio: L10n.processingDirectAudio
        }
    }
}

/// Persisted with the recording, before capture begins. Settings changes never alter this operation.
struct RecordingProcessing: Codable, Sendable {
    enum Stage: String, Codable { case recorded, transcribing, uploading, generating, summarizing, saving, succeeded, failed, cancelled }
    var id: UUID
    let automatic: Bool
    let liveDraft: Bool
    let localeIdentifier: String
    let method: RecordingProcessingMethod
    var options: SummaryGenerationOptions
    var generationSettings: SummaryGenerationSettings
    let serverSettings: ServerAccountSettings?
    var summaryMode: ServerAccountSettings.SummaryMode?
    var sessionIDs: [UUID] = []
    var stage: Stage = .recorded
    var error: String?
    var failedStage: Stage?
    var serverRequest: ServerSummaryService.Request?
    var retryOf: String?
    var summaryExpectation: SummaryGenerationExpectation?
    var generatedSummary: SummaryService.GeneratedSummary?
    var summaryApplied: Bool?

    var usesServerSummary: Bool? {
        if let summaryMode { return summaryMode == .remote }
        if serverRequest != nil || method != .transcript || serverSettings?.summary?.legacyMethod != nil { return true }
        return nil
    }

    mutating func prepareRetry(serverJob: ServerSummaryService.Job?) {
        if serverRequest == nil || serverJob?.isRetryable == true {
            id = .v7()
            summaryExpectation?.jobID = id
            retryOf = serverJob?.id
            if let body = serverRequest {
                serverRequest = .init(
                    id: id.uuidString.lowercased(), input: body.input, model: body.model,
                    detailLevel: body.detailLevel, summaryLanguage: body.summaryLanguage,
                    reasoningEffort: body.reasoningEffort
                )
            }
        }
        stage = method == .transcript ? .transcribing : .uploading
        error = nil
    }

    static func load(sessionID: UUID, in db: Database) throws -> Self? {
        guard let json = try RecordingSessionRecord.fetchOne(db, key: sessionID)?.processingJSON else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    func saveForRecordingStart(sessionID: UUID, in db: Database) throws {
        guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionID) else { throw CocoaError(.fileNoSuchFile) }
        var captured = self
        captured.sessionIDs = try RecordingSessionRecord
            .filter(Column("meetingId") == session.meetingId)
            .filter(Column("transcriptionMode") == "batch" && Column("batchDiscardedAt") == nil)
            .order(Column("startedAt").asc).fetchAll(db).map(\.id)
        try captured.save(sessionID: sessionID, in: db)
    }

    func save(sessionID: UUID, in db: Database) throws {
        let json = try String(decoding: JSONEncoder().encode(self), as: UTF8.self)
        try db.execute(sql: "UPDATE recording_sessions SET processingJSON = ? WHERE id = ?", arguments: [json, sessionID])
    }
}

/// The generated result may replace only the content against which it was requested.
struct SummaryGenerationExpectation: Codable, Sendable {
    let summaryDocument: String?
    let transcriptID: UUID?
    var recordingSessionID: UUID?
    var jobID: UUID?

    func validate(meetingID: UUID, in db: Database) throws {
        guard try SummaryBodyRecord.fetchOne(db, key: meetingID)?.document == summaryDocument,
              try TranscriptRecord.current(meetingID, in: db)?.id == transcriptID else { throw TextContentError.changed }
        if let recordingSessionID {
            guard let processing = try RecordingProcessing.load(sessionID: recordingSessionID, in: db),
                  processing.id == jobID, processing.stage != .cancelled else { throw CancellationError() }
        }
    }
}
