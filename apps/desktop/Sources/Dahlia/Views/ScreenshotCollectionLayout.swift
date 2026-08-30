import AppKit

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
        let metrics = Self.metrics(containerWidth: viewportWidth, minimumItemWidth: minimumItemWidth)
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
