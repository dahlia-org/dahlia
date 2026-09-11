import SwiftUI

struct ConversationAnalyticsDashboardView: View {
    @ObservedObject var store: MeetingConversationMetricsStore
    let load: () async -> Void

    var body: some View {
        Group {
            switch store.status {
            case .syncPending:
                ContentUnavailableView {
                    Label(L10n.conversationAnalyticsPending, systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L10n.conversationAnalyticsAvailableAfterSync)
                }
            case .noTranscript:
                ContentUnavailableView {
                    Label(L10n.conversationAnalytics, systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L10n.conversationAnalyticsEmpty)
                }
            case .ready:
                if let metrics = store.metrics, metrics.hasSegments {
                    ConversationAnalyticsDashboardContent(metrics: metrics)
                } else {
                    ContentUnavailableView {
                        Label(L10n.conversationAnalytics, systemImage: "chart.bar.xaxis")
                    } description: {
                        Text(L10n.conversationAnalyticsEmpty)
                    }
                }
            case .recordingAudioMissing:
                ContentUnavailableView {
                    Label(L10n.conversationAnalyticsAudioUnavailable, systemImage: "waveform.slash")
                } description: {
                    Text(L10n.conversationAnalyticsAudioUnavailableDescription)
                }
            case let .failed(errorMessage):
                ContentUnavailableView {
                    Label(L10n.conversationAnalyticsLoadFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.retry, action: retryLoad)
                }
            case .loading:
                ProgressView()
            case .hidden:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: store.target) {
            await load()
        }
    }

    private func retryLoad() {
        Task { await load() }
    }
}
