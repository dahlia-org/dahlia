import DahliaRuntimeSupport
import SwiftUI

struct SummaryTabContentView: View {
    @ObservedObject var screenshotStore: ScreenshotStore
    let document: SummaryDocument?
    let meetingDescription: String?
    let hasSummary: Bool
    let openScreenshot: (UUID, CGImage) -> Void
    let transcriptText: (TranscriptReference) -> String?

    var body: some View {
        if descriptionText != nil || summaryDocument != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: DahliaDesign.blockSpacing) {
                    if let descriptionText {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.descriptionTitle)
                                .font(.title2)
                                .bold()
                            Text(descriptionText)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let summaryDocument {
                        if descriptionText != nil {
                            Divider()
                        }
                        SummaryDocumentView(
                            document: summaryDocument,
                            screenshotProvider: screenshot,
                            onOpenImage: openScreenshot,
                            transcriptTextProvider: transcriptText
                        )
                    }
                }
                .frame(maxWidth: DahliaDesign.readingMaxWidth, alignment: .leading)
                .padding(.horizontal, DahliaDesign.readingHorizontalPadding)
                .padding(.vertical, DahliaDesign.tabContentInset)
                .frame(maxWidth: .infinity)
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

    private var descriptionText: String? {
        meetingDescription?.nilIfBlank
    }

    private var summaryDocument: SummaryDocument? {
        hasSummary ? document : nil
    }

    private func screenshot(for screenshotID: UUID) -> MeetingScreenshotRecord? {
        screenshotStore.records.first { $0.id == screenshotID }
    }
}
