import AppKit
import SwiftUI

@MainActor
struct ScreenshotCollectionView: NSViewRepresentable {
    let meetingID: UUID?
    let screenshots: [MeetingScreenshotRecord]
    let recordingSessions: [RecordingSessionTimeline]
    let fallbackTimeBase: Date
    let minimumItemWidth: Double
    let isSelecting: Bool
    let referencedScreenshotIDs: Set<UUID>
    let isDeletionDisabled: Bool
    @Binding var selectedScreenshotIDs: Set<UUID>
    let open: (MeetingScreenshotRecord, CGImage?) -> Void
    let download: (MeetingScreenshotRecord) -> Void
    let delete: (MeetingScreenshotRecord) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = ScreenshotCollectionLayout()
        layout.minimumItemWidth = minimumItemWidth

        let collectionView = NSCollectionView()
        collectionView.autoresizingMask = [.width]
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ScreenshotCollectionViewItem.self,
            forItemWithIdentifier: ScreenshotCollectionViewItem.reuseIdentifier
        )
        collectionView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        collectionView.frame = scrollView.contentView.bounds
        scrollView.documentView = collectionView

        context.coordinator.installDataSource(on: collectionView)
        context.coordinator.update(parent: self, collectionView: collectionView, layout: layout)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let collectionView = scrollView.documentView as? NSCollectionView,
              let layout = collectionView.collectionViewLayout as? ScreenshotCollectionLayout else { return }
        context.coordinator.update(parent: self, collectionView: collectionView, layout: layout)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let collectionView = scrollView.documentView as? NSCollectionView else { return }
        coordinator.dismantle(collectionView: collectionView)
    }
}

extension ScreenshotCollectionView {
    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate {
        private var parent: ScreenshotCollectionView
        private var dataSource: NSCollectionViewDiffableDataSource<Int, UUID>?
        private var currentScreenshotIDs: [UUID] = []
        private var screenshotIndexByID: [UUID: Int] = [:]
        private var currentScreenshotMetadata: [ScreenshotMetadata] = []
        private var timestampByID: [UUID: String] = [:]
        private var timestampContext: TimestampContext?
        private var lastPresentationState: PresentationState?
        private var currentMeetingID: UUID?
        private var lastBreadcrumbState: BreadcrumbState?
        private var snapshotGeneration: UInt64 = 0
        private(set) var timestampCacheGeneration: UInt64 = 0
        private(set) var isDismantled = false

        var snapshotItemIdentifiers: [UUID] {
            dataSource?.snapshot().itemIdentifiers ?? []
        }

        init(parent: ScreenshotCollectionView) {
            self.parent = parent
        }

        func installDataSource(on collectionView: NSCollectionView) {
            dataSource = NSCollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
                MainActor.assumeIsolated {
                    guard let self,
                          !self.isDismantled,
                          let item = collectionView.makeItem(
                              withIdentifier: ScreenshotCollectionViewItem.reuseIdentifier,
                              for: indexPath
                          ) as? ScreenshotCollectionViewItem else { return nil }
                    self.configure(item, id: id)
                    return item
                }
            }
        }

        func update(
            parent: ScreenshotCollectionView,
            collectionView: NSCollectionView,
            layout: ScreenshotCollectionLayout
        ) {
            guard !isDismantled else { return }
            self.parent = parent
            layout.minimumItemWidth = parent.minimumItemWidth

            let screenshots = parent.screenshots
            let ids = screenshots.map(\.id)
            let screenshotMetadata = screenshots.map(ScreenshotMetadata.init)
            let meetingChanged = currentMeetingID != parent.meetingID
            let identifiersChanged = Self.requiresSnapshotUpdate(
                currentIDs: currentScreenshotIDs,
                newIDs: ids
            )
            if identifiersChanged {
                screenshotIndexByID = Dictionary(
                    uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }
                )
            }
            let metadataChanged = currentScreenshotMetadata != screenshotMetadata
            currentMeetingID = parent.meetingID
            currentScreenshotIDs = ids
            currentScreenshotMetadata = screenshotMetadata

            let currentTimestampContext = TimestampContext(
                recordingSessions: parent.recordingSessions,
                fallbackTimeBase: parent.fallbackTimeBase
            )
            if meetingChanged || metadataChanged || timestampContext != currentTimestampContext {
                timestampByID = Dictionary(uniqueKeysWithValues: screenshots.map { ($0.id, timestamp(for: $0)) })
                timestampContext = currentTimestampContext
                timestampCacheGeneration &+= 1
            }

            applySnapshotIfNeeded(
                ids: ids,
                collectionView: collectionView,
                identifiersChanged: identifiersChanged,
                resetsScrollPosition: meetingChanged
            )

            let presentationState = PresentationState(
                isSelecting: parent.isSelecting,
                selectedScreenshotIDs: parent.selectedScreenshotIDs,
                referencedScreenshotIDs: parent.referencedScreenshotIDs,
                isDeletionDisabled: parent.isDeletionDisabled,
                timestampCacheGeneration: timestampCacheGeneration
            )
            if Self.requiresVisibleItemUpdate(previous: lastPresentationState, current: presentationState) {
                reconfigureVisibleItems(in: collectionView)
                lastPresentationState = presentationState
            }
            recordBreadcrumbIfNeeded(count: screenshots.count)
        }

        func dismantle(collectionView: NSCollectionView) {
            isDismantled = true
            snapshotGeneration &+= 1
            for item in collectionView.visibleItems() {
                (item as? ScreenshotCollectionViewItem)?.didEndDisplaying()
            }
            collectionView.delegate = nil
            collectionView.dataSource = nil
            dataSource = nil
            currentScreenshotIDs.removeAll()
            screenshotIndexByID.removeAll()
            currentScreenshotMetadata.removeAll()
            timestampByID.removeAll()
        }

        func collectionView(
            _: NSCollectionView,
            willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard let item = item as? ScreenshotCollectionViewItem,
                  let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            configure(item, id: id)
        }

        func collectionView(
            _: NSCollectionView,
            didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt _: IndexPath
        ) {
            (item as? ScreenshotCollectionViewItem)?.didEndDisplaying()
        }

        private func applySnapshotIfNeeded(
            ids: [UUID],
            collectionView: NSCollectionView,
            identifiersChanged: Bool,
            resetsScrollPosition: Bool
        ) {
            guard let dataSource else { return }
            guard identifiersChanged else {
                if resetsScrollPosition {
                    Self.scrollToTop(collectionView)
                }
                return
            }

            let preservedOrigin = collectionView.enclosingScrollView?.contentView.bounds.origin
            let appliedMeetingID = currentMeetingID
            snapshotGeneration &+= 1
            let appliedSnapshotGeneration = snapshotGeneration
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids, toSection: 0)
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self, weak collectionView] in
                guard let self,
                      let collectionView,
                      !self.isDismantled,
                      self.currentMeetingID == appliedMeetingID,
                      self.snapshotGeneration == appliedSnapshotGeneration else { return }
                if resetsScrollPosition {
                    Self.scrollToTop(collectionView)
                } else if let preservedOrigin {
                    Self.scroll(collectionView, to: preservedOrigin)
                }
            }
        }

        private func reconfigureVisibleItems(in collectionView: NSCollectionView) {
            let visibleItems = collectionView.visibleItems().compactMap { $0 as? ScreenshotCollectionViewItem }
            for item in visibleItems {
                guard let id = item.representedScreenshotID else { continue }
                configure(item, id: id)
            }
        }

        private func configure(_ item: ScreenshotCollectionViewItem, id: UUID) {
            guard let screenshot = screenshot(for: id), let timestamp = timestampByID[id] else { return }
            item.configure(
                .init(
                    screenshot: screenshot,
                    timestamp: timestamp,
                    isSelecting: parent.isSelecting,
                    isSelected: parent.selectedScreenshotIDs.contains(id),
                    isReferencedBySummary: parent.referencedScreenshotIDs.contains(id),
                    isDeletionDisabled: parent.isDeletionDisabled
                ),
                actions: .init(
                    activate: { [weak self] previewImage in
                        self?.activate(id: id, previewImage: previewImage)
                    },
                    download: { [weak self] in self?.download(id: id) },
                    delete: { [weak self] in self?.delete(id: id) }
                )
            )
        }

        private func activate(id: UUID, previewImage: CGImage?) {
            guard let screenshot = screenshot(for: id) else { return }
            if parent.isSelecting {
                guard !parent.referencedScreenshotIDs.contains(id) else { return }
                if parent.selectedScreenshotIDs.contains(id) {
                    parent.selectedScreenshotIDs.remove(id)
                } else {
                    parent.selectedScreenshotIDs.insert(id)
                }
            } else {
                parent.open(screenshot, previewImage)
            }
        }

        private func download(id: UUID) {
            guard let screenshot = screenshot(for: id) else { return }
            parent.download(screenshot)
        }

        private func delete(id: UUID) {
            guard let screenshot = screenshot(for: id) else { return }
            parent.delete(screenshot)
        }

        private func screenshot(for id: UUID) -> MeetingScreenshotRecord? {
            guard let index = screenshotIndexByID[id],
                  parent.screenshots.indices.contains(index),
                  parent.screenshots[index].id == id else { return nil }
            return parent.screenshots[index]
        }

        private func timestamp(for screenshot: MeetingScreenshotRecord) -> String {
            Formatters.elapsedHHmmss(
                at: screenshot.capturedAt,
                sessionId: screenshot.sessionId,
                sessions: parent.recordingSessions,
                fallbackTimeBase: parent.fallbackTimeBase
            )
        }

        private func recordBreadcrumbIfNeeded(count: Int) {
            let state = BreadcrumbState(
                countBucket: Self.countBucket(for: count),
                minimumWidthBucket: Self.minimumWidthBucket(for: parent.minimumItemWidth)
            )
            guard state != lastBreadcrumbState else { return }
            lastBreadcrumbState = state
            ErrorReportingService.recordScreenshotCollectionState(
                countBucket: state.countBucket,
                minimumWidthBucket: state.minimumWidthBucket
            )
        }

        private static func scrollToTop(_ collectionView: NSCollectionView) {
            scroll(collectionView, to: .zero)
        }

        private static func scroll(_ collectionView: NSCollectionView, to origin: NSPoint) {
            guard let scrollView = collectionView.enclosingScrollView else { return }
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        static func countBucket(for count: Int) -> Int {
            switch count {
            case ..<1: 0
            case 1 ..< 10: 1
            case 10 ..< 25: 10
            case 25 ..< 50: 25
            case 50 ..< 100: 50
            default: (count / 100) * 100
            }
        }

        static func minimumWidthBucket(for width: Double) -> Int {
            Int((width / 10).rounded()) * 10
        }

        static func requiresSnapshotUpdate(currentIDs: [UUID], newIDs: [UUID]) -> Bool {
            currentIDs != newIDs
        }

        static func requiresVisibleItemUpdate(
            previous: PresentationState?,
            current: PresentationState
        ) -> Bool {
            previous != current
        }

        struct PresentationState: Equatable {
            let isSelecting: Bool
            let selectedScreenshotIDs: Set<UUID>
            let referencedScreenshotIDs: Set<UUID>
            let isDeletionDisabled: Bool
            let timestampCacheGeneration: UInt64
        }

        private struct TimestampContext: Equatable {
            let recordingSessions: [RecordingSessionTimeline]
            let fallbackTimeBase: Date
        }

        private struct ScreenshotMetadata: Equatable {
            let id: UUID
            let sessionID: UUID?
            let capturedAt: Date
            let imageIdentity: ScreenshotImageContentIdentity

            init(_ screenshot: MeetingScreenshotRecord) {
                id = screenshot.id
                sessionID = screenshot.sessionId
                capturedAt = screenshot.capturedAt
                imageIdentity = ScreenshotImageContentIdentity(screenshot)
            }
        }

        private struct BreadcrumbState: Equatable {
            let countBucket: Int
            let minimumWidthBucket: Int
        }
    }
}
