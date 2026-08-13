import AppKit

@MainActor
final class SummaryViewAttachment: NSTextAttachment {
    let sizeProvider: (_ availableWidth: CGFloat) -> CGSize
    let hostedViewProvider: (SummaryViewAttachment) -> NSView
    let baselineOffset: CGFloat
    private let usesImageSizing: Bool
    private var imageAspectRatio: CGFloat?
    private weak var connectedTextLayoutManager: NSTextLayoutManager?
    private weak var connectedTextView: NSTextView?

    init(
        sizeProvider: @escaping (_ availableWidth: CGFloat) -> CGSize,
        usesImageSizing: Bool = false,
        baselineOffset: CGFloat = 0,
        hostedViewProvider: @escaping (SummaryViewAttachment) -> NSView
    ) {
        self.sizeProvider = sizeProvider
        self.usesImageSizing = usesImageSizing
        self.hostedViewProvider = hostedViewProvider
        self.baselineOffset = baselineOffset
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }

    func size(for availableWidth: CGFloat) -> CGSize {
        guard usesImageSizing else { return sizeProvider(availableWidth) }
        let width = max(1, availableWidth)
        let height = imageAspectRatio.map { width / $0 } ?? 120
        return CGSize(width: width, height: min(max(height, 120), 360))
    }

    func updateImageSize(_ image: CGImage) {
        guard usesImageSizing, image.height > 0 else { return }
        let aspectRatio = CGFloat(image.width) / CGFloat(image.height)
        guard imageAspectRatio != aspectRatio else { return }
        imageAspectRatio = aspectRatio
        if let documentRange = connectedTextLayoutManager?.textContentManager?.documentRange {
            connectedTextLayoutManager?.invalidateLayout(for: documentRange)
        }
        connectedTextView?.invalidateIntrinsicContentSize()
    }

    func connect(textLayoutManager: NSTextLayoutManager?, textView: NSTextView?) {
        connectedTextLayoutManager = textLayoutManager
        connectedTextView = textView
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("SummaryViewAttachment does not support decoding")
    }

    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        SummaryAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }
}
