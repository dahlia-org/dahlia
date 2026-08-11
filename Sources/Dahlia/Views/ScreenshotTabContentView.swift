import SwiftUI

struct ScreenshotTabContentView: View {
    @ObservedObject var screenshotStore: ScreenshotStore
    let meetingID: UUID?
    let recordingSessions: [RecordingSessionTimeline]
    let fallbackTimeBase: Date
    @Binding var minimumItemWidth: Double
    @Binding var isSelecting: Bool
    @Binding var selectedScreenshotIDs: Set<UUID>
    let referencedScreenshotIDs: Set<UUID>
    let isDeletionDisabled: Bool
    let open: (MeetingScreenshotRecord, CGImage?) -> Void
    let download: (MeetingScreenshotRecord) -> Void
    let delete: (MeetingScreenshotRecord) -> Void
    let deleteSelected: () -> Void

    var body: some View {
        if screenshotStore.records.isEmpty {
            ContentUnavailableView {
                Label(L10n.screenshots, systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(L10n.noScreenshotsYet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ScreenshotManagementToolbar(
                    minimumWidth: $minimumItemWidth,
                    isSelecting: $isSelecting,
                    selectedCount: selectedScreenshotIDs.count,
                    canSelectAll: selectedScreenshotIDs.count < deletableScreenshotIDs.count,
                    isDeletionDisabled: isDeletionDisabled,
                    selectAll: selectAllScreenshots,
                    deleteSelected: deleteSelected
                )
                .padding(12)

                Divider()

                ScreenshotCollectionView(
                    meetingID: meetingID,
                    screenshots: screenshotStore.records,
                    contentRevision: screenshotStore.contentRevision,
                    recordingSessions: recordingSessions,
                    fallbackTimeBase: fallbackTimeBase,
                    minimumItemWidth: minimumItemWidth,
                    isSelecting: isSelecting,
                    referencedScreenshotIDs: referencedScreenshotIDs,
                    isDeletionDisabled: isDeletionDisabled,
                    selectedScreenshotIDs: $selectedScreenshotIDs,
                    open: open,
                    download: download,
                    delete: delete
                )
                .padding(.horizontal, DahliaDesign.tabContentInset)
                .padding(.bottom, DahliaDesign.tabContentInset)
            }
        }
    }

    private var deletableScreenshotIDs: Set<UUID> {
        Set(screenshotStore.records.map(\.id)).subtracting(referencedScreenshotIDs)
    }

    private func selectAllScreenshots() {
        selectedScreenshotIDs = deletableScreenshotIDs
    }
}
