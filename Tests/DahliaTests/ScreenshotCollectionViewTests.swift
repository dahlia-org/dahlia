import AppKit
import CoreGraphics
import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct ScreenshotCollectionViewTests {
    @Test
    func layoutUsesAdaptiveColumnsAndStableAspectRatio() {
        let metrics = ScreenshotCollectionLayout.metrics(containerWidth: 1_000, minimumItemWidth: 200)

        #expect(metrics.columnCount == 4)
        #expect(metrics.itemSize.width == 235)
        #expect(metrics.itemSize.height == 161)
    }

    @Test
    func layoutSupportsSmallTilesAndNarrowContainers() {
        let smallTiles = ScreenshotCollectionLayout.metrics(containerWidth: 1_000, minimumItemWidth: 110)
        let narrowContainer = ScreenshotCollectionLayout.metrics(containerWidth: 80, minimumItemWidth: 200)

        #expect(smallTiles.columnCount == 8)
        #expect(smallTiles.itemSize.width == 111)
        #expect(narrowContainer.columnCount == 1)
        #expect(narrowContainer.itemSize.width == 56)
        #expect(narrowContainer.itemSize.height > ScreenshotCollectionLayout.metadataHeight)
    }

    @Test
    func snapshotUpdatesOnlyWhenIdentifiersChange() {
        let first = UUID.v7()
        let second = UUID.v7()
        let otherMeeting = UUID.v7()

        #expect(ScreenshotCollectionView.Coordinator.requiresSnapshotUpdate(currentIDs: [], newIDs: [first]))
        #expect(!ScreenshotCollectionView.Coordinator.requiresSnapshotUpdate(currentIDs: [first], newIDs: [first]))
        #expect(ScreenshotCollectionView.Coordinator.requiresSnapshotUpdate(currentIDs: [first], newIDs: [first, second]))
        #expect(ScreenshotCollectionView.Coordinator.requiresSnapshotUpdate(currentIDs: [first, second], newIDs: [second]))
        #expect(ScreenshotCollectionView.Coordinator.requiresSnapshotUpdate(currentIDs: [first, second], newIDs: [otherMeeting]))
    }

    @Test
    func sameIdentifierStateChangesOnlyReconfigureVisibleItems() {
        let screenshotID = UUID.v7()
        let unchanged = ScreenshotCollectionView.Coordinator.PresentationState(
            isSelecting: false,
            selectedScreenshotIDs: [],
            referencedScreenshotIDs: [],
            isDeletionDisabled: false,
            timestampCacheGeneration: 1
        )
        let selected = ScreenshotCollectionView.Coordinator.PresentationState(
            isSelecting: true,
            selectedScreenshotIDs: [screenshotID],
            referencedScreenshotIDs: [],
            isDeletionDisabled: false,
            timestampCacheGeneration: 1
        )

        #expect(!ScreenshotCollectionView.Coordinator.requiresVisibleItemUpdate(previous: unchanged, current: unchanged))
        #expect(ScreenshotCollectionView.Coordinator.requiresVisibleItemUpdate(previous: unchanged, current: selected))
    }

    @Test
    func breadcrumbCountsUseBoundedBuckets() {
        #expect(ScreenshotCollectionView.Coordinator.countBucket(for: 0) == 0)
        #expect(ScreenshotCollectionView.Coordinator.countBucket(for: 9) == 1)
        #expect(ScreenshotCollectionView.Coordinator.countBucket(for: 24) == 10)
        #expect(ScreenshotCollectionView.Coordinator.countBucket(for: 99) == 50)
        #expect(ScreenshotCollectionView.Coordinator.countBucket(for: 245) == 200)
        #expect(ScreenshotCollectionView.Coordinator.minimumWidthBucket(for: 110) == 110)
        #expect(ScreenshotCollectionView.Coordinator.minimumWidthBucket(for: 164) == 160)
        #expect(ScreenshotCollectionView.Coordinator.minimumWidthBucket(for: 200) == 200)
    }

    @Test
    func preparingForReuseReleasesLoadedThumbnail() async throws {
        let item = ScreenshotCollectionViewItem()
        let screenshot = makeScreenshot()
        let image = try #require(makeImage(width: 32, height: 18))

        configure(item, screenshot: screenshot) { _, _, _ in image }
        await waitUntil { item.loadedThumbnailSize != nil }
        #expect(item.loadedThumbnailSize == NSSize(width: 32, height: 18))

        item.prepareForReuse()

        #expect(item.representedScreenshotID == nil)
        #expect(item.loadedThumbnailSize == nil)
    }

    @Test
    func endingDisplayReleasesImageIdentifierAndCallbacks() async throws {
        let item = ScreenshotCollectionViewItem()
        let screenshot = makeScreenshot()
        let image = try #require(makeImage(width: 32, height: 18))

        configure(item, screenshot: screenshot) { _, _, _ in image }
        await waitUntil { item.loadedThumbnailSize != nil }

        item.didEndDisplaying()

        #expect(item.loadedThumbnailSize == nil)
        #expect(item.representedScreenshotID == nil)
        #expect(!item.hasCallbacks)
    }

    @Test
    func reusedCellAppliesSelectionLockAndDeletionState() {
        let item = ScreenshotCollectionViewItem()
        let first = makeScreenshot()
        let second = makeScreenshot()
        let provider: ScreenshotCollectionViewItem.ThumbnailProvider = { _, _, _ in nil }

        configure(
            item,
            screenshot: first,
            state: .init(isSelecting: true, isReferencedBySummary: true),
            provider: provider
        )
        #expect(!item.selectionIndicatorAcceptsHitTesting)
        #expect(!item.selectionIndicatorIsAccessibilityElement)
        #expect(item.renderedState == .init(
            isThumbnailEnabled: false,
            isLockVisible: true,
            selectionSymbolName: "lock.circle.fill",
            isDeleteHidden: true,
            isDeleteEnabled: false
        ))

        item.prepareForReuse()
        configure(
            item,
            screenshot: second,
            state: .init(isSelecting: true, isSelected: true),
            provider: provider
        )
        #expect(item.renderedState == .init(
            isThumbnailEnabled: true,
            isLockVisible: false,
            selectionSymbolName: "checkmark.circle.fill",
            isDeleteHidden: true,
            isDeleteEnabled: true
        ))

        configure(
            item,
            screenshot: second,
            state: .init(isDeletionDisabled: true),
            provider: provider
        )
        #expect(item.renderedState == .init(
            isThumbnailEnabled: true,
            isLockVisible: false,
            selectionSymbolName: nil,
            isDeleteHidden: false,
            isDeleteEnabled: false
        ))
    }

    @Test
    func nativeButtonsRouteOpenDownloadAndDeleteActionsWithImmediatePreview() async throws {
        let item = ScreenshotCollectionViewItem()
        let screenshot = makeScreenshot()
        let preview = try #require(makeImage(width: 32, height: 18))
        var invokedActions: [String] = []
        var activatedPreviewSize: CGSize?
        item.configure(
            .init(
                screenshot: screenshot,
                timestamp: "00:00:01",
                isSelecting: false,
                isSelected: false,
                isReferencedBySummary: false,
                isDeletionDisabled: false
            ),
            thumbnailProvider: { _, _, _ in preview },
            actions: .init(
                activate: { image in
                    activatedPreviewSize = image.map { CGSize(width: $0.width, height: $0.height) }
                    invokedActions.append("open")
                },
                download: { invokedActions.append("download") },
                delete: { invokedActions.append("delete") }
            )
        )
        await waitUntil { item.loadedThumbnailSize != nil }

        let buttons = descendantViews(of: item.view).compactMap { $0 as? NSButton }
        let openButton = try #require(buttons.first { $0.accessibilityLabel() == L10n.open })
        let downloadButton = try #require(buttons.first { $0.accessibilityLabel() == L10n.download })
        let deleteButton = try #require(buttons.first { $0.accessibilityLabel() == L10n.delete })

        openButton.performClick(nil)
        downloadButton.performClick(nil)
        deleteButton.performClick(nil)

        #expect(invokedActions == ["open", "download", "delete"])
        #expect(activatedPreviewSize == CGSize(width: 32, height: 18))
    }

    @Test
    func staleDecodeResultCannotReplaceReusedCellImage() async throws {
        let item = ScreenshotCollectionViewItem()
        let first = makeScreenshot()
        let second = makeScreenshot()
        let provider = ControlledThumbnailProvider()
        let firstImage = try #require(makeImage(width: 40, height: 20))
        let secondImage = try #require(makeImage(width: 24, height: 12))

        configure(item, screenshot: first, provider: provider.image)
        await waitUntilAsync { await provider.hasRequest(for: first.id) }

        configure(item, screenshot: second, provider: provider.image)
        await waitUntilAsync { await provider.hasRequest(for: second.id) }
        await provider.resolve(id: second.id, image: secondImage)
        await waitUntil { item.loadedThumbnailSize == NSSize(width: 24, height: 12) }

        await provider.resolve(id: first.id, image: firstImage)
        await Task.yield()

        #expect(item.representedScreenshotID == second.id)
        #expect(item.loadedThumbnailSize == NSSize(width: 24, height: 12))
    }

    @Test
    func failedDecodeDoesNotRetryUntilTheCellIsRedisplayed() async throws {
        let item = ScreenshotCollectionViewItem()
        let screenshot = makeScreenshot()
        let image = try #require(makeImage(width: 30, height: 15))
        let provider = SequencedThumbnailProvider(successfulImage: image)
        let provideThumbnail: ScreenshotCollectionViewItem.ThumbnailProvider = { id, data, maxPixelSize in
            await provider.image(id: id, data: data, maxPixelSize: maxPixelSize)
        }

        configure(item, screenshot: screenshot, provider: provideThumbnail)
        await waitUntilAsync { await provider.callCount == 1 }
        await waitUntil { !item.isLoadingThumbnail }

        configure(
            item,
            screenshot: screenshot,
            state: .init(isSelecting: true),
            provider: provideThumbnail
        )
        await Task.yield()
        #expect(await provider.callCount == 1)

        item.didEndDisplaying()
        configure(item, screenshot: screenshot, provider: provideThumbnail)
        await waitUntilAsync { await provider.callCount == 2 }
        await waitUntil { item.loadedThumbnailSize == NSSize(width: 30, height: 15) }

        #expect(item.representedScreenshotID == screenshot.id)
    }

    @Test
    func changedImageDataReloadsThumbnailForTheSameIdentifier() async throws {
        let item = ScreenshotCollectionViewItem()
        let original = makeScreenshot()
        var updated = original
        updated.imageData = Data([1])
        let originalImage = try #require(makeImage(width: 32, height: 18))
        let updatedImage = try #require(makeImage(width: 40, height: 20))
        let originalData = original.imageData
        let provider: ScreenshotCollectionViewItem.ThumbnailProvider = { _, data, _ in
            data == originalData ? originalImage : updatedImage
        }

        configure(item, screenshot: original, provider: provider)
        await waitUntil { item.loadedThumbnailSize == NSSize(width: 32, height: 18) }

        configure(item, screenshot: updated, provider: provider)
        await waitUntil { item.loadedThumbnailSize == NSSize(width: 40, height: 20) }

        #expect(item.representedScreenshotID == original.id)
    }

    private func configure(
        _ item: ScreenshotCollectionViewItem,
        screenshot: MeetingScreenshotRecord,
        state: TestControlState = .init(),
        provider: @escaping ScreenshotCollectionViewItem.ThumbnailProvider
    ) {
        item.configure(
            .init(
                screenshot: screenshot,
                timestamp: "00:00:01",
                isSelecting: state.isSelecting,
                isSelected: state.isSelected,
                isReferencedBySummary: state.isReferencedBySummary,
                isDeletionDisabled: state.isDeletionDisabled
            ),
            thumbnailProvider: provider,
            actions: .init(activate: { _ in }, download: {}, delete: {})
        )
    }

    private func descendantViews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendantViews)
    }

    private struct TestControlState {
        var isSelecting = false
        var isSelected = false
        var isReferencedBySummary = false
        var isDeletionDisabled = false
    }

    private func makeScreenshot() -> MeetingScreenshotRecord {
        MeetingScreenshotRecord(
            id: .v7(),
            meetingId: .v7(),
            capturedAt: .now,
            imageData: Data([0]),
            mimeType: "image/png"
        )
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )?.makeImage()
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0 ..< 1_000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for MainActor state")
    }

    private func waitUntilAsync(_ predicate: @escaping @Sendable () async -> Bool) async {
        for _ in 0 ..< 1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for asynchronous state")
    }
}

extension ScreenshotCollectionViewTests {
    @Test
    func imageIdentityMatchesEqualContentFromSeparateAllocations() {
        let bytes = (0 ..< 256).map { UInt8($0 % 251) }
        var first = makeScreenshot()
        first.imageData = Data(bytes)
        var second = first
        second.imageData = bytes.withUnsafeBytes { Data($0) }

        #expect(ScreenshotImageContentIdentity(first) == ScreenshotImageContentIdentity(second))
    }

    @Test
    func imageIdentityDetectsSampledContentChanges() {
        var original = makeScreenshot()
        original.imageData = Data(repeating: 0, count: 256)
        var changed = original
        changed.imageData[changed.imageData.count / 2] = 1

        #expect(ScreenshotImageContentIdentity(original) != ScreenshotImageContentIdentity(changed))
    }
}

private actor ControlledThumbnailProvider {
    private var continuations: [UUID: CheckedContinuation<CGImage?, Never>] = [:]

    func image(id: UUID, data _: Data, maxPixelSize _: Int) async -> CGImage? {
        await withCheckedContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func hasRequest(for id: UUID) -> Bool {
        continuations[id] != nil
    }

    func resolve(id: UUID, image: CGImage?) {
        continuations.removeValue(forKey: id)?.resume(returning: image)
    }
}

private actor SequencedThumbnailProvider {
    private let successfulImage: CGImage
    private(set) var callCount = 0

    init(successfulImage: CGImage) {
        self.successfulImage = successfulImage
    }

    func image(id _: UUID, data _: Data, maxPixelSize _: Int) -> CGImage? {
        callCount += 1
        return callCount == 1 ? nil : successfulImage
    }
}
#endif
