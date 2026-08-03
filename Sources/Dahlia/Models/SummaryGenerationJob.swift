import Foundation

/// A single meeting-scoped summary generation and its optional exports.
@MainActor @Observable
final class SummaryGenerationJob: Identifiable {
    let id = UUID.v7()
    let meetingId: UUID
    let meetingName: String
    let startedAt: Date
    let progress = SummaryProgressState()

    init(
        meetingId: UUID,
        meetingName: String,
        includesTranscription: Bool = false,
        startedAt: Date = .now
    ) {
        self.meetingId = meetingId
        self.meetingName = meetingName
        self.startedAt = startedAt
        if includesTranscription {
            progress.transcription = .running
        }
    }

    var hasFailure: Bool {
        stepStatuses.contains(where: \.isFailed)
    }

    var isFinished: Bool {
        stepStatuses.allSatisfy(\.isTerminal)
    }

    func configureExports(_ options: SummaryExportOptions) {
        progress.vaultExport = options.exportsToVault ? .pending : .skipped
        progress.googleDocsExport = options.exportsToGoogleDocs ? .pending : .skipped
    }

    private var stepStatuses: [SummaryProgressState.StepStatus] {
        [progress.transcription, progress.summaryGeneration, progress.vaultExport, progress.googleDocsExport]
    }
}
