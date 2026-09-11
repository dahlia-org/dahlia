import SwiftUI

struct SummaryGenerationSourcePicker: View {
    @Binding var selection: SummaryGenerationSource?
    let availability: SummaryGenerationSourceAvailability?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        Picker(L10n.summaryGenerationSource, selection: $selection) {
            ForEach(SummaryGenerationSource.allCases) { source in
                VStack(alignment: .leading) {
                    Text(title(for: source))
                    Text(description(for: source))
                        .foregroundStyle(.secondary)
                    if let reason = unavailableReason(for: source) {
                        Text(reason)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(Optional(source))
                .disabled(availability?.isAvailable(source) != true)
            }
        }
        .labelsHidden()
        .pickerStyle(.radioGroup)

        if isLoading {
            ProgressView(L10n.summarySourceChecking)
                .controlSize(.small)
        } else if let errorMessage {
            SettingsStatusMessage(
                text: errorMessage,
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            )
        } else if availability?.preferredSource == nil {
            Label(L10n.summarySourceNoneAvailable, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    private func title(for source: SummaryGenerationSource) -> String {
        switch source {
        case .transcript: L10n.summarySourceTranscript
        case .audio: L10n.summarySourceAudio
        }
    }

    private func description(for source: SummaryGenerationSource) -> String {
        switch source {
        case .transcript: L10n.summarySourceTranscriptDescription
        case .audio: L10n.summarySourceAudioDescription
        }
    }

    private func unavailableReason(for source: SummaryGenerationSource) -> String? {
        guard !isLoading else { return L10n.summarySourceChecking }
        guard errorMessage == nil, let availability else { return nil }
        guard availability.supportedSources.contains(source) else {
            return source == .audio && !availability.usesServer
                ? L10n.summarySourceAudioRequiresServer
                : L10n.summarySourceUnsupported
        }
        let missing = availability.meetingCount - availability.availableCount(for: source)
        guard missing > 0 else { return nil }
        if availability.meetingCount > 1 {
            switch source {
            case .transcript: return L10n.summarySourceMissingTranscripts(missing)
            case .audio: return L10n.summarySourceMissingAudio(missing)
            }
        }
        switch source {
        case .transcript: return L10n.summarySourceTranscriptUnavailable
        case .audio: return L10n.summarySourceAudioUnavailable
        }
    }
}
