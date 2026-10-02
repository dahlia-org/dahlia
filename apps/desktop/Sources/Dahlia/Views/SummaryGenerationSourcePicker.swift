import SwiftUI

struct SummaryGenerationSourceStatus: View {
    let availability: SummaryGenerationSourceAvailability?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        Text(L10n.summarySourceTranscriptDescription)
            .foregroundStyle(.secondary)
        if isLoading {
            ProgressView(L10n.summarySourceChecking).controlSize(.small)
        } else if let errorMessage {
            SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
        } else if availability?.isAvailable(.transcript) != true {
            Label(L10n.summarySourceTranscriptUnavailable, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}
