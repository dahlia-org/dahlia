import SwiftUI

struct BatchTranscriptionStatusBanner: View {
    let state: BatchTranscriptionState
    let canAct: Bool
    let actionTitle: String
    let onAction: () -> Void
    let onDiscard: () -> Void
    let onKeepCurrentTranscript: () -> Void

    var body: some View {
        switch state {
        case .awaitingConfirmation:
            BatchTranscriptionInfoBanner(
                message: L10n.batchTranscriptionAwaitingConfirmation,
                systemImage: "waveform.badge.magnifyingglass",
                showsProgress: false,
                actionTitle: actionTitle,
                isActionEnabled: canAct,
                onAction: onAction
            )
        case .queued:
            BatchTranscriptionInfoBanner(
                message: L10n.batchTranscriptionQueued,
                systemImage: "clock",
                showsProgress: false,
                actionTitle: nil,
                isActionEnabled: false,
                onAction: onAction
            )
        case let .running(_, progress):
            BatchTranscriptionInfoBanner(
                message: runningMessage(progress),
                systemImage: "waveform",
                showsProgress: true,
                actionTitle: nil,
                isActionEnabled: false,
                onAction: onAction
            )
        case let .interrupted(_, isRetranscription):
            if isRetranscription {
                BatchTranscriptionFailureBanner(
                    message: L10n.batchTranscriptionInterrupted,
                    canRetry: canAct,
                    isRetranscription: true,
                    onRetry: onAction,
                    onDiscard: onDiscard,
                    onKeepCurrentTranscript: onKeepCurrentTranscript
                )
            } else {
                BatchTranscriptionInfoBanner(
                    message: L10n.batchTranscriptionInterrupted,
                    systemImage: "pause.circle",
                    showsProgress: false,
                    actionTitle: actionTitle,
                    isActionEnabled: canAct,
                    onAction: onAction
                )
            }
        case let .failed(_, message):
            BatchTranscriptionFailureBanner(
                message: message,
                canRetry: canAct,
                isRetranscription: false,
                onRetry: onAction,
                onDiscard: onDiscard,
                onKeepCurrentTranscript: onKeepCurrentTranscript
            )
        case let .retranscriptionFailed(_, message):
            BatchTranscriptionFailureBanner(
                message: message,
                canRetry: canAct,
                isRetranscription: true,
                onRetry: onAction,
                onDiscard: onDiscard,
                onKeepCurrentTranscript: onKeepCurrentTranscript
            )
        case .recording, .completed:
            EmptyView()
        }
    }

    private func runningMessage(_ progress: BatchTranscriptionProgress?) -> String {
        guard let progress else { return L10n.batchTranscriptionRunning }
        return "\(L10n.batchTranscriptionRunning) \(L10n.batchTranscriptionFileProgress(completed: progress.completedFileCount, total: progress.totalFileCount))"
    }

}
