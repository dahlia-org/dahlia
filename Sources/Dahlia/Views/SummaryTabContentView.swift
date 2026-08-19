import DahliaRuntimeSupport
import SwiftUI

struct SummaryTabContentView: View {
    @ObservedObject var screenshotStore: ScreenshotStore
    let document: SummaryDocument?
    let hasSummary: Bool
    let openScreenshot: (UUID, CGImage) -> Void
    let transcriptText: (TranscriptReference) -> String?

    var body: some View {
        if hasSummary, let document {
            ScrollView {
                SummaryDocumentView(
                    document: document,
                    screenshotProvider: screenshot,
                    onOpenImage: openScreenshot,
                    transcriptTextProvider: transcriptText
                )
                .padding(.horizontal, DahliaDesign.detailHorizontalPadding)
                .padding(.vertical, DahliaDesign.tabContentInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label(L10n.summary, systemImage: "list.bullet.clipboard")
            } description: {
                Text(L10n.noSummaryYet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func screenshot(for screenshotID: UUID) -> MeetingScreenshotRecord? {
        screenshotStore.records.first { $0.id == screenshotID }
    }
}
