import SwiftUI

struct MeetingListPaginationRow: View {
    let error: String?
    let hasItems: Bool
    let isLoadingMore: Bool
    let hasMore: Bool
    let limitMessage: String?
    let loadTrigger: String
    let onRetry: () -> Void
    let onLoadMore: () -> Void

    var body: some View {
        if let error, hasItems {
            Button(
                L10n.retryLoadingMeetings,
                systemImage: "arrow.clockwise",
                action: onRetry
            )
            .help(error)
        } else if isLoadingMore {
            loadingRow
        } else if hasMore {
            loadingRow
                .id(loadTrigger)
                .onAppear(perform: onLoadMore)
        } else if let limitMessage {
            Text(limitMessage)
                .font(DahliaDesign.sidebarFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text(L10n.loadingMoreMeetings)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
