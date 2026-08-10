import Foundation

enum UsageTelemetryEvent: Equatable, Sendable {
    enum Lifecycle<FailureStage: RawRepresentable & Equatable & Sendable>: Equatable, Sendable
        where FailureStage.RawValue == String {
        case started
        case completed
        case failed(FailureStage)

        fileprivate var signalSuffix: String {
            switch self {
            case .started: "started"
            case .completed: "completed"
            case .failed: "failed"
            }
        }

        fileprivate var failureStage: String? {
            guard case let .failed(stage) = self else { return nil }
            return stage.rawValue
        }
    }

    enum TranscriptionModeValue: String, CaseIterable, Sendable {
        case realtime
        case batch
    }

    enum AudioSources: String, CaseIterable, Sendable {
        case microphone
        case systemAudio
        case microphoneAndSystemAudio
    }

    enum RecordingFailureStage: String, CaseIterable, Sendable {
        case start
        case capture
        case stop
        case persistence
    }

    enum TranscriptionFailureStage: String, CaseIterable, Sendable {
        case start
        case persistence
        case transcription
    }

    enum SummaryFailureStage: String, CaseIterable, Sendable {
        case generation
    }

    enum ExportFailureStage: String, CaseIterable, Sendable {
        case export
    }

    enum SummaryTrigger: String, CaseIterable, Sendable {
        case manual
        case automaticAfterBatch
    }

    enum ExportTrigger: String, CaseIterable, Sendable {
        case manual
        case summaryGeneration
    }

    enum ExportDestination: String, CaseIterable, Sendable {
        case vault
        case googleDocs
        case localFiles
    }

    case recording(Lifecycle<RecordingFailureStage>, mode: TranscriptionModeValue, sources: AudioSources)
    case transcription(Lifecycle<TranscriptionFailureStage>, mode: TranscriptionModeValue)
    case summary(Lifecycle<SummaryFailureStage>, trigger: SummaryTrigger)
    case export(Lifecycle<ExportFailureStage>, destination: ExportDestination, trigger: ExportTrigger)

    var signalName: String {
        switch self {
        case let .recording(lifecycle, _, _):
            "Dahlia.Recording.\(lifecycle.signalSuffix)"
        case let .transcription(lifecycle, _):
            "Dahlia.Transcription.\(lifecycle.signalSuffix)"
        case let .summary(lifecycle, _):
            "Dahlia.Summary.\(lifecycle.signalSuffix)"
        case let .export(lifecycle, _, _):
            "Dahlia.Export.\(lifecycle.signalSuffix)"
        }
    }

    var parameters: [String: String] {
        switch self {
        case let .recording(lifecycle, mode, sources):
            parameters(
                ["transcriptionMode": mode.rawValue, "audioSources": sources.rawValue],
                failureStage: lifecycle.failureStage
            )
        case let .transcription(lifecycle, mode):
            parameters(["transcriptionMode": mode.rawValue], failureStage: lifecycle.failureStage)
        case let .summary(lifecycle, trigger):
            parameters(["trigger": trigger.rawValue], failureStage: lifecycle.failureStage)
        case let .export(lifecycle, destination, trigger):
            parameters(
                ["destination": destination.rawValue, "trigger": trigger.rawValue],
                failureStage: lifecycle.failureStage
            )
        }
    }

    private func parameters(
        _ base: [String: String],
        failureStage: String?
    ) -> [String: String] {
        var result = base
        result["stage"] = failureStage
        return result
    }
}

extension UsageTelemetryEvent.TranscriptionModeValue {
    init(_ mode: TranscriptionMode) {
        self = mode == .realtime ? .realtime : .batch
    }
}

extension UsageTelemetryEvent.AudioSources {
    init?(sources: Set<RecordingAudioSource>) {
        let hasMicrophone = sources.contains(.microphone)
        let hasSystemAudio = sources.contains(.system)
        switch (hasMicrophone, hasSystemAudio) {
        case (true, true): self = .microphoneAndSystemAudio
        case (true, false): self = .microphone
        case (false, true): self = .systemAudio
        case (false, false): return nil
        }
    }
}
