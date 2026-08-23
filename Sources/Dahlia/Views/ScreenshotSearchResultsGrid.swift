import SwiftUI

struct ScreenshotSearchResultsGrid: View {
    let results: [ScreenshotSearchResult]
    let selectedResultID: MainSearchResultID?
    let hasMore: Bool
    let isLoading: Bool
    let imageDataProvider: (UUID) async -> Data?
    let onOpen: (ScreenshotSearchResult) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        LazyVGrid(columns: MainSearchDesign.screenshotColumns, spacing: MainSearchDesign.screenshotGridSpacing) {
            ForEach(results) { screenshot in
                ScreenshotSearchResultTile(
                    result: screenshot,
                    isSelected: selectedResultID == .screenshot(screenshot.id),
                    imageDataProvider: imageDataProvider,
                    action: { onOpen(screenshot) }
                )
                .id(MainSearchResultID.screenshot(screenshot.id))
            }
        }

        if hasMore {
            Button(L10n.loadMore, action: onLoadMore)
                .buttonStyle(.plain)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .disabled(isLoading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }
}
