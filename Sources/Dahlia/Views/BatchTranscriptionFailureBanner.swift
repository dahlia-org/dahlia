import SwiftUI

struct BatchTranscriptionFailureBanner: View {
    let message: String
    let canRetry: Bool
    let isRetranscription: Bool
    let onRetry: () -> Void
    let onDiscard: () -> Void
    let onKeepCurrentTranscript: () -> Void
    @State private var isConfirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading) {
            Label(L10n.batchTranscriptionFailed(message), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            HStack {
                if canRetry {
                    Button(L10n.retryBatchTranscription, systemImage: "arrow.clockwise", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }

                Spacer()

                if isRetranscription {
                    Button(L10n.keepCurrentTranscript, action: onKeepCurrentTranscript)
                } else {
                    Button(L10n.discardFailedBatchRecording, role: .destructive) {
                        isConfirmingDiscard = true
                    }
                }
            }
        }
        .padding()
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, DahliaDesign.detailHorizontalPadding)
        .padding(.vertical, 4)
        .confirmationDialog(
            L10n.discardFailedBatchRecordingConfirmation,
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(L10n.discardFailedBatchRecording, role: .destructive, action: onDiscard)
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.discardFailedBatchRecordingDescription)
        }
    }
}
