import SwiftUI

struct MeetingDetailInspector<Screenshots: View>: View {
    @ObservedObject var viewModel: CaptionViewModel
    @Binding var mode: DetailInspectorMode
    @Binding var evidenceTab: EvidenceInspectorTab
    let requestedTranscriptSegmentID: UUID?
    let referenceResolutionMessage: String?
    @ViewBuilder let screenshots: () -> Screenshots
    @ObservedObject private var appSettings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.inspector, selection: $mode) {
                ForEach(DetailInspectorMode.availableModes(
                    isAnalysisEnabled: appSettings.isConversationAnalyticsBetaEnabled
                )) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            if let referenceResolutionMessage {
                Label(referenceResolutionMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            switch mode {
            case .evidence:
                evidence
            case .analysis:
                ConversationAnalyticsDashboardView(
                    store: viewModel.conversationMetricsStore,
                    meetingId: viewModel.currentMeetingId,
                    isAnalysisPending: viewModel.isCurrentMeetingConversationAnalysisPending,
                    hasTranscript: viewModel.currentMeetingHasTranscriptSegments,
                    load: viewModel.loadCurrentMeetingConversationMetrics
                )
            }
        }
        .onChange(of: appSettings.isConversationAnalyticsBetaEnabled) { _, isEnabled in
            if !isEnabled {
                mode = .evidence
            }
        }
    }

    private var evidence: some View {
        VStack(spacing: 0) {
            Picker(L10n.evidence, selection: $evidenceTab) {
                ForEach(EvidenceInspectorTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            switch evidenceTab {
            case .transcript:
                TranscriptTabView(
                    store: viewModel.store,
                    allowsTextSelection: !viewModel.isListening,
                    showsTranslatedText: appSettings.isTranscriptTranslationEffectivelyEnabled,
                    retryInitialMeetingLoad: viewModel.retryInitialMeetingLoad,
                    requestedSegmentID: requestedTranscriptSegmentID
                )
            case .screenshots:
                screenshots()
            }
        }
    }
}
