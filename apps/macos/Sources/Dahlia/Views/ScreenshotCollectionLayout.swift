import AppKit
import SwiftUI

final class ScreenshotCollectionLayout: NSCollectionViewFlowLayout {
    struct Metrics: Equatable {
        let columnCount: Int
        let itemSize: NSSize
    }

    static let sectionPadding: CGFloat = 12
    static let itemSpacing: CGFloat = 12
    static let metadataHeight: CGFloat = 36

    var minimumItemWidth = CGFloat(ScreenshotGridSizing.defaultMinimumWidth) {
        didSet {
            guard minimumItemWidth != oldValue else { return }
            invalidateLayout()
        }
    }

    var pageHeader: NSHostingView<AnyView>?
    var pageFooter: NSHostingView<AnyView>?
    private var headerContent: AnyView?
    private var footerContent: AnyView?
    private var measuredWidth: CGFloat?

    func setPageContent(header: AnyView?, footer: AnyView?) {
        measuredWidth = nil
        headerContent = header
        footerContent = footer
        if let header, pageHeader == nil { pageHeader = NSHostingView(rootView: header) }
        if let footer, pageFooter == nil { pageFooter = NSHostingView(rootView: footer) }
        if header == nil { pageHeader = nil }
        if footer == nil { pageFooter = nil }
        invalidateLayout()
    }

    private func pageSize(_ content: AnyView?, host: NSHostingView<AnyView>?, width: CGFloat) -> NSSize {
        guard let content, let host, width > 0 else { return .zero }
        host.rootView = AnyView(content.frame(maxWidth: DahliaDesign.mainContentMaxWidth).frame(width: width).fixedSize(
            horizontal: false,
            vertical: true
        ))
        return NSSize(width: width, height: host.fittingSize.height)
    }

    override init() {
        super.init()
        scrollDirection = .vertical
        minimumInteritemSpacing = Self.itemSpacing
        minimumLineSpacing = Self.itemSpacing
        sectionInset = NSEdgeInsets(
            top: Self.sectionPadding,
            left: Self.sectionPadding,
            bottom: Self.sectionPadding,
            right: Self.sectionPadding
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        guard let collectionView else {
            super.prepare()
            return
        }

        let viewportWidth = collectionView.bounds.width
        if measuredWidth != viewportWidth {
            let headerSize = pageSize(headerContent, host: pageHeader, width: viewportWidth)
            let footerSize = pageSize(footerContent, host: pageFooter, width: viewportWidth)
            if headerReferenceSize != headerSize { headerReferenceSize = headerSize }
            if footerReferenceSize != footerSize { footerReferenceSize = footerSize }
            measuredWidth = viewportWidth
        }
        let contentWidth = min(viewportWidth, DahliaDesign.mainContentMaxWidth)
        let sideInset = Self.sectionPadding + max(0, (viewportWidth - contentWidth) / 2)
        sectionInset.left = sideInset
        sectionInset.right = sideInset
        let metrics = Self.metrics(containerWidth: contentWidth, minimumItemWidth: minimumItemWidth)
        if itemSize != metrics.itemSize {
            itemSize = metrics.itemSize
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return false }
        return newBounds.width != collectionView.bounds.width
    }

    static func metrics(containerWidth: CGFloat, minimumItemWidth: CGFloat) -> Metrics {
        let horizontalPadding = sectionPadding * 2
        let availableWidth = max(containerWidth - horizontalPadding, 1)
        let resolvedMinimumWidth = max(minimumItemWidth, 1)
        let columnCount = max(1, Int((availableWidth + itemSpacing) / (resolvedMinimumWidth + itemSpacing)))
        let totalSpacing = CGFloat(columnCount - 1) * itemSpacing
        let itemWidth = max(1, ((availableWidth - totalSpacing) / CGFloat(columnCount)).rounded(.down))
        let thumbnailWidth = max(1, itemWidth - 12)
        let thumbnailHeight = (thumbnailWidth * 9 / 16).rounded(.down)
        return Metrics(
            columnCount: columnCount,
            itemSize: NSSize(width: itemWidth, height: thumbnailHeight + metadataHeight)
        )
    }
}
