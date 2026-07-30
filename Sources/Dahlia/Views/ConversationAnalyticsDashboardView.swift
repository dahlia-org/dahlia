import SwiftUI

struct ConversationAnalyticsDashboardView: View {
    @ObservedObject var store: MeetingConversationMetricsStore
    let meetingId: UUID?
    let isAnalysisPending: Bool
    let hasTranscript: Bool
    let load: () async -> Void

    private var loadIdentity: String {
        [
            meetingId?.uuidString ?? "none",
            String(store.reloadToken),
            String(hasTranscript),
            String(isAnalysisPending),
        ]
        .joined(separator: ":")
    }

    var body: some View {
        Group {
            if isAnalysisPending {
                ContentUnavailableView {
                    Label(L10n.conversationAnalyticsPending, systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L10n.conversationAnalyticsAvailableAfterTranscription)
                }
            } else if !hasTranscript {
                ContentUnavailableView {
                    Label(L10n.conversationAnalytics, systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L10n.conversationAnalyticsEmpty)
                }
            } else if let metrics = store.metrics {
                if metrics.hasSegments {
                    ConversationAnalyticsDashboardContent(metrics: metrics)
                } else {
                    ContentUnavailableView {
                        Label(L10n.conversationAnalytics, systemImage: "chart.bar.xaxis")
                    } description: {
                        Text(L10n.conversationAnalyticsEmpty)
                    }
                }
            } else if let errorMessage = store.errorMessage {
                ContentUnavailableView {
                    Label(L10n.conversationAnalyticsLoadFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.retry, action: retryLoad)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: loadIdentity) {
            guard hasTranscript, !isAnalysisPending else { return }
            await load()
        }
    }

    private func retryLoad() {
        Task { await load() }
    }
}
