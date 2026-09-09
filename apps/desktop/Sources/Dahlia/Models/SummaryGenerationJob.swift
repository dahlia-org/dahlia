import Foundation

/// A single meeting-scoped summary generation and its optional exports.
@MainActor @Observable
final class SummaryGenerationJob: Identifiable {
    let id: UUID
    var recordingSessionID: UUID?
    var stageLabel: String?
    var task: Task<Void, Never>?
    var cancel: (() -> Void)?
    var retry: (() -> Void)?
    var isCancelled = false
    let meetingId: UUID
    let meetingName: String
    let startedAt: Date
    let progress = SummaryProgressState()

    init(
        id: UUID = .v7(),
        meetingId: UUID,
        meetingName: String,
        includesTranscription: Bool = false,
        startedAt: Date = .now
    ) {
        self.id = id
        self.meetingId = meetingId
        self.meetingName = meetingName
        self.startedAt = startedAt
        if includesTranscription {
            progress.transcription = .running
        }
    }

    func showStage(_ stage: String) {
        stageLabel = switch stage {
        case "uploading": L10n.processingUploading
        case "transcribing": L10n.processingTranscribing
        case "summarizing": L10n.processingSummarizing
        case "generating": L10n.processingGenerating
        case "saving": L10n.processingSaving
        default: L10n.waiting
        }
        progress.transcriptionProgress = nil
        if stage == "summarizing" { progress.transcription = .completed }
    }

    var hasFailure: Bool {
        stepStatuses.contains(where: \.isFailed)
    }

    var isFinished: Bool {
        isCancelled || stepStatuses.allSatisfy(\.isTerminal)
    }

    func configureExports(_ options: SummaryExportOptions) {
        progress.vaultExport = options.exportsToVault ? .pending : .skipped
        progress.googleDocsExport = options.exportsToGoogleDocs ? .pending : .skipped
    }

    private var stepStatuses: [SummaryProgressState.StepStatus] {
        [progress.transcription, progress.summaryGeneration, progress.vaultExport, progress.googleDocsExport]
    }
}
