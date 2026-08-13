import DahliaRuntimeSupport
import SwiftUI

struct SummarySelectableTextView: NSViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let document: SummaryDocument
    let transcriptRevision: UInt64
    let screenshotRevisionProvider: (UUID) -> UInt64?
    let screenshotProvider: (UUID) -> MeetingScreenshotRecord?
    let onOpenImage: (UUID, CGImage) -> Void
    let transcriptTextProvider: (TranscriptReference) -> String?
    let allowsTranscriptReferencePopovers: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenImage: onOpenImage)
    }

    func makeNSView(context _: Context) -> SummarySelectableNSTextView {
        SummarySelectableNSTextView.makeConfigured()
    }

    func updateNSView(_ textView: SummarySelectableNSTextView, context: Context) {
        context.coordinator.onOpenImage = onOpenImage
        let screenshotRevisions = document.orderedScreenshotIds.map(screenshotRevisionProvider)
        let inputs = RenderInputs(
            document: document,
            screenshotRevisions: screenshotRevisions,
            transcriptRevision: transcriptRevision,
            dynamicTypeSize: dynamicTypeSize,
            allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
        )
        guard context.coordinator.renderInputs != inputs else { return }
        context.coordinator.renderInputs = inputs

        let transcriptTexts = SummaryAttributedDocument.transcriptReferences(in: document).map(transcriptTextProvider)
        let renderIdentity = RenderIdentity(
            document: document,
            screenshotRevisions: screenshotRevisions,
            transcriptTexts: transcriptTexts,
            dynamicTypeSize: dynamicTypeSize,
            allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
        )
        guard context.coordinator.renderIdentity != renderIdentity else { return }
        context.coordinator.renderIdentity = renderIdentity

        textView.setDocument(SummaryAttributedDocument.render(
            document,
            screenshotProvider: screenshotProvider,
            onOpenImage: context.coordinator.openImage,
            transcriptTextProvider: transcriptTextProvider,
            allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
        ))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: SummarySelectableNSTextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width,
              let height = textView.measuredHeight(constrainedTo: width)
        else { return nil }

        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator {
        var onOpenImage: (UUID, CGImage) -> Void
        var renderInputs: RenderInputs?
        var renderIdentity: RenderIdentity?

        init(onOpenImage: @escaping (UUID, CGImage) -> Void) {
            self.onOpenImage = onOpenImage
        }

        func openImage(_ id: UUID, _ image: CGImage) {
            onOpenImage(id, image)
        }
    }

    struct RenderInputs: Equatable {
        let document: SummaryDocument
        let screenshotRevisions: [UInt64?]
        let transcriptRevision: UInt64
        let dynamicTypeSize: DynamicTypeSize
        let allowsTranscriptReferencePopovers: Bool
    }

    struct RenderIdentity: Equatable {
        let document: SummaryDocument
        let screenshotRevisions: [UInt64?]
        let transcriptTexts: [String?]
        let dynamicTypeSize: DynamicTypeSize
        let allowsTranscriptReferencePopovers: Bool
    }
}
