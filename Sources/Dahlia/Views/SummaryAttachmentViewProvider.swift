import AppKit

@MainActor
final class SummaryAttachmentViewProvider: NSTextAttachmentViewProvider {
    private weak var connectedTextView: NSTextView?

    override init(
        textAttachment: NSTextAttachment,
        parentView: NSView?,
        textLayoutManager: NSTextLayoutManager?,
        location: any NSTextLocation
    ) {
        connectedTextView = parentView as? NSTextView
        super.init(
            textAttachment: textAttachment,
            parentView: parentView,
            textLayoutManager: textLayoutManager,
            location: location
        )
    }

    // SwiftFormat and SwiftLint prescribe opposite orders for this AppKit override combination.
    // swiftlint:disable:next modifier_order
    override nonisolated func loadView() {
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? SummaryViewAttachment else { return }

            provider.view = attachment.hostedViewProvider(attachment)
            provider.tracksTextAttachmentViewBounds = true
        }
    }

    // swiftlint:disable:next modifier_order
    override nonisolated func attachmentBounds(
        for _: [NSAttributedString.Key: Any],
        location _: any NSTextLocation,
        textContainer _: NSTextContainer?,
        proposedLineFragment: CGRect,
        position _: CGPoint
    ) -> CGRect {
        nonisolated(unsafe) let provider = self
        return MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? SummaryViewAttachment else { return CGRect.zero }

            attachment.connect(
                textLayoutManager: provider.textLayoutManager,
                textView: provider.connectedTextView
            )
            let size = attachment.size(for: proposedLineFragment.width)
            provider.view?.frame.size = size
            return CGRect(
                x: 0,
                y: attachment.baselineOffset,
                width: size.width,
                height: size.height
            )
        }
    }
}
