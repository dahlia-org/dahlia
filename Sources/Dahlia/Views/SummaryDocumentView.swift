import DahliaRuntimeSupport
import SwiftUI

struct SummaryDocumentView: View {
    let document: SummaryDocument
    let transcriptRevision: UInt64
    let screenshotRevisionProvider: (UUID) -> UInt64?
    let screenshotProvider: (UUID) -> MeetingScreenshotRecord?
    let onOpenImage: (UUID, CGImage) -> Void
    let transcriptTextProvider: (TranscriptReference) -> String?
    let allowsTranscriptReferencePopovers: Bool

    init(
        document: SummaryDocument,
        transcriptRevision: UInt64 = 0,
        screenshotRevisionProvider: @escaping (UUID) -> UInt64? = { _ in nil },
        screenshotProvider: @escaping (UUID) -> MeetingScreenshotRecord?,
        onOpenImage: @escaping (UUID, CGImage) -> Void,
        transcriptTextProvider: @escaping (TranscriptReference) -> String? = { _ in nil },
        allowsTranscriptReferencePopovers: Bool = true
    ) {
        self.document = document
        self.transcriptRevision = transcriptRevision
        self.screenshotRevisionProvider = screenshotRevisionProvider
        self.screenshotProvider = screenshotProvider
        self.onOpenImage = onOpenImage
        self.transcriptTextProvider = transcriptTextProvider
        self.allowsTranscriptReferencePopovers = allowsTranscriptReferencePopovers
    }

    var body: some View {
        SummarySelectableTextView(
            document: document,
            transcriptRevision: transcriptRevision,
            screenshotRevisionProvider: screenshotRevisionProvider,
            screenshotProvider: screenshotProvider,
            onOpenImage: onOpenImage,
            transcriptTextProvider: transcriptTextProvider,
            allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
        )
    }
}
