import SwiftUI

struct BatchTranscriptionStatusView: View {
    let state: BatchTranscriptionState
    let confirm: () -> Void
    let retry: () -> Void
    let cancelRetranscription: () -> Void
    let discard: () -> Void

    @State private var isShowingDiscardConfirmation = false

    var body: some View {
        HStack {
            switch state {
            case .recording:
                ProgressView()
                    .controlSize(.small)
                Text(L10n.batchRecordingInProgress)
            case .awaitingConfirmation:
                Label(L10n.batchTranscriptionAwaitingConfirmation, systemImage: "clock")
                Spacer()
                Button(L10n.reviewBatchTranscription, action: confirm)
            case .queued:
                ProgressView()
                    .controlSize(.small)
                Text(L10n.batchTranscriptionQueued)
            case let .running(_, progress):
                if let progress, progress.totalFileCount > 0 {
                    ProgressView(
                        value: Double(progress.completedFileCount),
                        total: Double(progress.totalFileCount)
                    ) {
                        Text(L10n.batchTranscriptionRunning)
                    } currentValueLabel: {
                        Text(L10n.batchTranscriptionFileProgress(
                            completed: progress.completedFileCount,
                            total: progress.totalFileCount
                        ))
                    }
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(L10n.batchTranscriptionRunning)
                    .accessibilityValue(L10n.batchTranscriptionFileProgress(
                        completed: progress.completedFileCount,
                        total: progress.totalFileCount
                    ))
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.batchTranscriptionRunning)
                }
            case .completed:
                Label(L10n.batchTranscriptionCompleted, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(_, message):
                Label(L10n.batchTranscriptionFailed(message), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button(L10n.retryBatchTranscription, action: retry)
                Button(
                    L10n.discardFailedBatchRecording,
                    role: .destructive,
                    action: showDiscardConfirmation
                )
            case let .retranscriptionFailed(_, message):
                Label(L10n.batchTranscriptionFailed(message), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button(L10n.keepCurrentTranscript, action: cancelRetranscription)
                Button(L10n.retryBatchTranscription, action: retry)
            }
        }
        .font(.callout)
        .padding()
        .background(.quaternary)
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            L10n.discardFailedBatchRecordingConfirmation,
            isPresented: $isShowingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.discardFailedBatchRecording, role: .destructive, action: discard)
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.discardFailedBatchRecordingDescription)
        }
    }

    private func showDiscardConfirmation() {
        isShowingDiscardConfirmation = true
    }
}
