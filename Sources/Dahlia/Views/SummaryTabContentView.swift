import SwiftUI

struct SummaryTabContentView: View {
    @ObservedObject var screenshotStore: ScreenshotStore
    let document: SummaryDocument?
    let hasSummary: Bool
    let allowsTranscriptReferencePopovers: Bool
    let openScreenshot: (UUID, CGImage) -> Void
    let transcriptText: (TranscriptReference) -> String?

    var body: some View {
        if let document, hasSummary {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SummaryDocumentView(
                        document: document,
                        imageDataProvider: imageData,
                        onOpenImage: openScreenshot,
                        transcriptTextProvider: transcriptText,
                        allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
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

    private func imageData(for screenshotID: UUID) -> Data? {
        screenshotStore.records.first { $0.id == screenshotID }?.imageData
    }
}
