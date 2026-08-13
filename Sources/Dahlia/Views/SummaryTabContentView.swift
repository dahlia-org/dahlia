import DahliaRuntimeSupport
import SwiftUI

struct SummaryTabContentView: View {
    @ObservedObject var screenshotStore: ScreenshotStore
    @ObservedObject var transcriptStore: TranscriptStore
    let document: SummaryDocument?
    let hasSummary: Bool
    let allowsTranscriptReferencePopovers: Bool
    let openScreenshot: (UUID, CGImage) -> Void

    var body: some View {
        if let document, hasSummary {
            ScrollView {
                SummaryDocumentView(
                    document: document,
                    transcriptRevision: transcriptStore.summaryReferenceRevision,
                    screenshotRevisionProvider: { screenshotStore.contentRevision(for: $0) },
                    screenshotProvider: screenshot,
                    onOpenImage: openScreenshot,
                    transcriptTextProvider: transcriptText,
                    allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
                )
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

    private func screenshot(for screenshotID: UUID) -> MeetingScreenshotRecord? {
        screenshotStore.records.first { $0.id == screenshotID }
    }

    private func transcriptText(for reference: TranscriptReference) -> String? {
        let time = reference.time.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !time.isEmpty else { return nil }

        let recordingSessions = transcriptStore.recordingSessions
        return transcriptStore.segments.first { segment in
            Formatters.elapsedHHmmss(
                at: segment.startTime,
                sessionId: segment.sessionId,
                sessions: recordingSessions,
                fallbackTimeBase: transcriptStore.timeBase
            ) == time
        }?.displayText.nilIfBlank
    }
}
