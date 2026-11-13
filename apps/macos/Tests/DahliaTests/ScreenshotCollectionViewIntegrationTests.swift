import AppKit
import Foundation
import SwiftUI
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    extension ScreenshotCollectionViewTests {
        @Test
        func commandClickStartsSelectionAndTogglesIndividualScreenshots() {
            let meetingID = UUID.v7()
            let screenshots = makeScreenshots(count: 4, meetingID: meetingID)
            let selection = SelectionBox([])
            let actions = CollectionActionRecorder()
            let input = makeCollectionInput(
                meetingID: meetingID, screenshots: screenshots,
                actionRecorder: actions, selectionBox: selection
            )
            let harness = ScreenshotCollectionHarness(parent: input)

            harness.coordinator.activate(id: screenshots[0].id, previewImage: nil, modifiers: .command)
            #expect(selection.isSelecting)
            #expect(selection.value == [screenshots[0].id])
            #expect(actions.openedScreenshot == nil)
            harness.coordinator.activate(id: screenshots[3].id, previewImage: nil, modifiers: .command)
            #expect(selection.value == [screenshots[0].id, screenshots[3].id])
            harness.coordinator.activate(id: screenshots[0].id, previewImage: nil, modifiers: .command)
            #expect(selection.value == [screenshots[3].id])
            // Existing selection-mode clicks keep toggling without modifier keys.
            harness.coordinator.activate(id: screenshots[2].id, previewImage: nil, modifiers: [])
            #expect(selection.value == [screenshots[2].id, screenshots[3].id])
        }

        @Test
        func shiftClickSelectsRangesInBothDirectionsAndSkipsReferencedImages() {
            let meetingID = UUID.v7()
            let screenshots = makeScreenshots(count: 6, meetingID: meetingID)
            let selection = SelectionBox([])
            let input = makeCollectionInput(
                meetingID: meetingID, screenshots: screenshots, selectionBox: selection,
                referencedScreenshotIDs: [screenshots[2].id]
            )
            let harness = ScreenshotCollectionHarness(parent: input)

            harness.coordinator.activate(id: screenshots[1].id, previewImage: nil, modifiers: .command)
            harness.coordinator.activate(id: screenshots[4].id, previewImage: nil, modifiers: .shift)
            #expect(selection.value == Set([1, 3, 4].map { screenshots[$0].id }))
            harness.coordinator.activate(id: screenshots[3].id, previewImage: nil, modifiers: .shift)
            #expect(selection.value == Set([1, 3].map { screenshots[$0].id }))
            harness.coordinator.activate(id: screenshots[5].id, previewImage: nil, modifiers: .command)
            harness.coordinator.activate(id: screenshots[3].id, previewImage: nil, modifiers: [.command, .shift])
            #expect(selection.value == Set([1, 3, 4, 5].map { screenshots[$0].id }))
            harness.coordinator.activate(id: screenshots[2].id, previewImage: nil, modifiers: .command)
            #expect(!selection.value.contains(screenshots[2].id))
        }

        @Test
        func selectionAnchorResetsOnExitAndMeetingChangeAndSurvivesRemoval() {
            let meetingID = UUID.v7()
            let screenshots = makeScreenshots(count: 5, meetingID: meetingID)
            let selection = SelectionBox([])
            var input = makeCollectionInput(
                meetingID: meetingID, screenshots: screenshots, selectionBox: selection
            )
            let harness = ScreenshotCollectionHarness(parent: input)
            harness.coordinator.activate(id: screenshots[0].id, previewImage: nil, modifiers: .shift)
            #expect(selection.value == [screenshots[0].id])
            harness.update(parent: input)
            selection.isSelecting = false
            selection.value = []
            harness.update(parent: input)
            harness.coordinator.activate(id: screenshots[3].id, previewImage: nil, modifiers: .shift)
            #expect(selection.value == [screenshots[3].id])

            input = makeCollectionInput(
                meetingID: meetingID, screenshots: screenshots.filter { $0.id != screenshots[3].id },
                selectionBox: selection
            )
            harness.update(parent: input)
            harness.coordinator.activate(id: screenshots[1].id, previewImage: nil, modifiers: .shift)
            #expect(selection.value == [screenshots[1].id])
            input = makeCollectionInput(
                meetingID: UUID.v7(), screenshots: screenshots, selectionBox: selection
            )
            harness.update(parent: input)
            harness.coordinator.activate(id: screenshots[4].id, previewImage: nil, modifiers: .shift)
            #expect(selection.value == [screenshots[4].id])
        }

        @Test
        func disabledDeletionPreventsModifierSelectionButAllowsOpening() {
            let meetingID = UUID.v7()
            let screenshots = makeScreenshots(count: 1, meetingID: meetingID)
            let selection = SelectionBox([])
            let actions = CollectionActionRecorder()
            let input = makeCollectionInput(
                meetingID: meetingID, screenshots: screenshots,
                actionRecorder: actions, selectionBox: selection, isDeletionDisabled: true
            )
            let harness = ScreenshotCollectionHarness(parent: input)
            for modifiers: NSEvent.ModifierFlags in [.command, .shift] {
                harness.coordinator.activate(id: screenshots[0].id, previewImage: nil, modifiers: modifiers)
            }
            #expect(selection.value.isEmpty)
            #expect(!selection.isSelecting)
            #expect(actions.openedScreenshot == nil)
            harness.coordinator.activate(id: screenshots[0].id, previewImage: nil, modifiers: [])
            #expect(actions.openedScreenshot?.id == screenshots[0].id)
        }

        @Test
        func wideViewportCentersGridWithoutNarrowingScrollView() {
            let layout = ScreenshotCollectionLayout()
            let collection = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 1400, height: 360))
            collection.collectionViewLayout = layout
            layout.prepare()
            #expect(collection.bounds.width == 1400)
            #expect(layout.sectionInset.left == 212)
            #expect(layout.sectionInset.right == 212)
            #expect(layout.itemSize == ScreenshotCollectionLayout.metrics(
                containerWidth: DahliaDesign.mainContentMaxWidth,
                minimumItemWidth: layout.minimumItemWidth
            ).itemSize)
        }

        @Test
        func pageHeaderAndFooterShareTheCollectionScrollLayout() {
            let layout = ScreenshotCollectionLayout()
            let collection = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            collection.collectionViewLayout = layout
            layout.setPageContent(
                header: AnyView(Color.clear.frame(height: 180)),
                footer: AnyView(Color.clear.frame(height: 40))
            )
            layout.prepare()
            #expect(layout.headerReferenceSize == NSSize(width: 640, height: 180))
            #expect(layout.footerReferenceSize == NSSize(width: 640, height: 40))
            collection.frame.size.width = 500
            layout.prepare()
            #expect(layout.headerReferenceSize.width == 500)
            layout.setPageContent(header: nil, footer: nil)
            layout.prepare()
            #expect(layout.headerReferenceSize == .zero)
            #expect(layout.footerReferenceSize == .zero)
        }

        @Test
        func layoutPreparationAndInvalidationUseCollectionBoundsWidth() {
            let layout = ScreenshotCollectionLayout()
            let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 700, height: 360))
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            collectionView.collectionViewLayout = layout
            scrollView.documentView = collectionView
            collectionView.frame.size.width = 700

            layout.prepare()

            #expect(layout.itemSize == ScreenshotCollectionLayout.metrics(
                containerWidth: collectionView.bounds.width,
                minimumItemWidth: layout.minimumItemWidth
            ).itemSize)
            #expect(!layout.shouldInvalidateLayout(forBoundsChange: collectionView.bounds))
            #expect(layout.shouldInvalidateLayout(forBoundsChange: NSRect(
                x: 0,
                y: 0,
                width: collectionView.bounds.width + 1,
                height: collectionView.bounds.height
            )))
        }

        @Test
        func pageHeaderScrollsAwayWhileScreenshotCellsStayVirtualized() async throws {
            let meetingID = UUID.v7()
            let screenshots = makeScreenshots(count: 500, meetingID: meetingID)
            var input = makeCollectionInput(meetingID: meetingID, screenshots: screenshots)
            input.pageHeader = AnyView(Color.clear.frame(height: 180))
            input.pageFooter = AnyView(Color.clear.frame(height: 40))
            let harness = ScreenshotCollectionHarness(parent: input)
            await integrationWaitUntil { harness.coordinator.snapshotItemIdentifiers.count == 500 }
            harness.layoutViews()
            let layout = try #require(harness.collectionView.collectionViewLayout)
            let header = try #require(layout.layoutAttributesForSupplementaryView(
                ofKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 0)
            ))
            #expect(header.frame.height == 180)
            harness.scroll(toY: 240)
            harness.layoutViews()
            #expect(harness.scrollView.contentView.bounds.minY > header.frame.maxY)
            #expect(harness.collectionView.visibleItems().count < 100)
        }

        @Test
        func coordinatorAppliesSnapshotsPreservesUpdatesAndResetsMeetingScroll() async {
            let firstMeetingID = UUID.v7()
            let secondMeetingID = UUID.v7()
            let initialScreenshots = makeScreenshots(count: 80, meetingID: firstMeetingID)
            let initialInput = makeCollectionInput(meetingID: firstMeetingID, screenshots: initialScreenshots)
            let harness = ScreenshotCollectionHarness(parent: initialInput)

            await integrationWaitUntil { harness.coordinator.snapshotItemIdentifiers == initialScreenshots.map(\.id) }
            harness.layoutViews()
            harness.scroll(toY: 240)
            let preservedOrigin = harness.scrollView.contentView.bounds.origin.y
            #expect(preservedOrigin > 0)

            let appendedScreenshots = initialScreenshots + makeScreenshots(count: 1, meetingID: firstMeetingID)
            harness.update(parent: makeCollectionInput(meetingID: firstMeetingID, screenshots: appendedScreenshots))
            await integrationWaitUntil { harness.coordinator.snapshotItemIdentifiers == appendedScreenshots.map(\.id) }
            await integrationWaitUntil { harness.scrollView.contentView.bounds.origin.y == preservedOrigin }

            let deletedScreenshots = Array(appendedScreenshots.dropFirst())
            harness.update(parent: makeCollectionInput(meetingID: firstMeetingID, screenshots: deletedScreenshots))
            await integrationWaitUntil { harness.coordinator.snapshotItemIdentifiers == deletedScreenshots.map(\.id) }
            await integrationWaitUntil { harness.scrollView.contentView.bounds.origin.y == preservedOrigin }

            harness.scroll(toY: 320)
            let secondMeetingScreenshots = makeScreenshots(count: 30, meetingID: secondMeetingID)
            harness.update(parent: makeCollectionInput(meetingID: secondMeetingID, screenshots: secondMeetingScreenshots))
            await integrationWaitUntil { harness.coordinator.snapshotItemIdentifiers == secondMeetingScreenshots.map(\.id) }
            await integrationWaitUntil { harness.scrollView.contentView.bounds.origin.y == 0 }
        }

        @Test
        func coordinatorSkipsTimestampRebuildForUnrelatedAndSelectionUpdates() {
            let meetingID = UUID.v7()
            let screenshots = makeScreenshots(count: 20, meetingID: meetingID)
            let initialInput = makeCollectionInput(
                meetingID: meetingID,
                screenshots: screenshots,
                contentRevision: 1
            )
            let harness = ScreenshotCollectionHarness(parent: initialInput)
            let initialGeneration = harness.coordinator.timestampCacheGeneration

            harness.update(parent: initialInput)
            #expect(harness.coordinator.timestampCacheGeneration == initialGeneration)

            harness.update(parent: makeCollectionInput(
                meetingID: meetingID,
                screenshots: screenshots,
                contentRevision: 1,
                selectedScreenshotIDs: [screenshots[0].id]
            ))
            #expect(harness.coordinator.timestampCacheGeneration == initialGeneration)

            let session = RecordingSessionTimeline(
                id: .v7(),
                startedAt: .now,
                endedAt: nil,
                offsetSeconds: 0
            )
            harness.update(parent: makeCollectionInput(
                meetingID: meetingID,
                screenshots: screenshots,
                contentRevision: 1,
                recordingSessions: [session]
            ))
            #expect(harness.coordinator.timestampCacheGeneration == initialGeneration + 1)
        }

        @Test
        func sameIdentifierRecordUpdateRefreshesTimestampAndActionRecord() async throws {
            let meetingID = UUID.v7()
            let actionRecorder = CollectionActionRecorder()
            let original = makeScreenshots(count: 1, meetingID: meetingID)[0]
            let harness = ScreenshotCollectionHarness(parent: makeCollectionInput(
                meetingID: meetingID,
                screenshots: [original],
                contentRevision: 1,
                actionRecorder: actionRecorder
            ))
            let initialGeneration = harness.coordinator.timestampCacheGeneration

            var updated = original
            updated.capturedAt = original.capturedAt.addingTimeInterval(60)
            updated.imageData = Data([1, 2, 3])
            harness.update(parent: makeCollectionInput(
                meetingID: meetingID,
                screenshots: [updated],
                contentRevision: 2,
                actionRecorder: actionRecorder
            ))

            #expect(harness.coordinator.timestampCacheGeneration == initialGeneration + 1)
            await integrationWaitUntil { harness.collectionView.item(at: IndexPath(item: 0, section: 0)) != nil }
            let item = try #require(
                harness.collectionView.item(at: IndexPath(item: 0, section: 0)) as? ScreenshotCollectionViewItem
            )
            let openButton = try #require(
                integrationDescendantViews(of: item.view)
                    .compactMap { $0 as? NSButton }
                    .first { $0.accessibilityLabel() == L10n.open }
            )
            openButton.performClick(nil)

            #expect(actionRecorder.openedScreenshot?.capturedAt == updated.capturedAt)
            #expect(actionRecorder.openedScreenshot?.imageData == updated.imageData)
        }

        @Test
        func fiveHundredScreenshotsCreateOnlyVisibleItems() async {
            let meetingID = UUID.v7()
            let screenshots = makeScreenshots(count: 500, meetingID: meetingID)
            let harness = ScreenshotCollectionHarness(
                parent: makeCollectionInput(meetingID: meetingID, screenshots: screenshots)
            )

            await integrationWaitUntil { harness.coordinator.snapshotItemIdentifiers.count == 500 }
            harness.layoutViews()
            await integrationWaitUntil { !harness.collectionView.visibleItems().isEmpty }

            #expect(harness.collectionView.visibleItems().count < 50)
        }

        @Test
        func dismantlingCollectionInvalidatesPendingUpdatesAndReleasesVisibleItems() async {
            let meetingID = UUID.v7()
            let screenshots = makeScreenshots(count: 100, meetingID: meetingID)
            let harness = ScreenshotCollectionHarness(
                parent: makeCollectionInput(meetingID: meetingID, screenshots: screenshots)
            )
            await integrationWaitUntil { !harness.collectionView.visibleItems().isEmpty }
            let visibleItems = harness.collectionView.visibleItems().compactMap { $0 as? ScreenshotCollectionViewItem }

            ScreenshotCollectionView.dismantleNSView(harness.scrollView, coordinator: harness.coordinator)

            #expect(harness.coordinator.isDismantled)
            #expect(harness.coordinator.snapshotItemIdentifiers.isEmpty)
            #expect(harness.collectionView.delegate == nil)
            #expect(harness.collectionView.dataSource == nil)
            #expect(visibleItems.allSatisfy { $0.representedScreenshotID == nil && !$0.isLoadingThumbnail })
        }

        private func makeCollectionInput(
            meetingID: UUID,
            screenshots: [MeetingScreenshotRecord],
            contentRevision: UInt64? = nil,
            recordingSessions: [RecordingSessionTimeline] = [],
            selectedScreenshotIDs: Set<UUID> = [],
            actionRecorder: CollectionActionRecorder? = nil,
            selectionBox: SelectionBox? = nil,
            referencedScreenshotIDs: Set<UUID> = [],
            isDeletionDisabled: Bool = false
        ) -> ScreenshotCollectionView {
            let selection = selectionBox ?? SelectionBox(selectedScreenshotIDs)
            return ScreenshotCollectionView(
                meetingID: meetingID,
                screenshots: screenshots,
                contentRevision: contentRevision,
                recordingSessions: recordingSessions,
                fallbackTimeBase: Date(timeIntervalSince1970: 0),
                minimumItemWidth: ScreenshotGridSizing.defaultMinimumWidth,
                isSelecting: Binding(get: { selection.isSelecting }, set: { selection.isSelecting = $0 }),
                referencedScreenshotIDs: referencedScreenshotIDs,
                isDeletionDisabled: isDeletionDisabled,
                selectedScreenshotIDs: Binding(
                    get: { selection.value },
                    set: { selection.value = $0 }
                ),
                open: { screenshot, _ in actionRecorder?.openedScreenshot = screenshot },
                download: { actionRecorder?.downloadedScreenshot = $0 },
                delete: { actionRecorder?.deletedScreenshot = $0 }
            )
        }

        private func makeScreenshots(count: Int, meetingID: UUID) -> [MeetingScreenshotRecord] {
            (0 ..< count).map { index in
                MeetingScreenshotRecord(
                    id: .v7(),
                    meetingId: meetingID,
                    capturedAt: Date(timeIntervalSince1970: Double(index)),
                    imageData: Data(),
                    mimeType: "image/png"
                )
            }
        }

        private func integrationWaitUntil(_ predicate: @MainActor () -> Bool) async {
            if await pollUntil({ predicate() }) { return }
            Issue.record("Timed out waiting for MainActor state")
        }

        private func integrationDescendantViews(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(integrationDescendantViews)
        }
    }

    @MainActor
    private final class ScreenshotCollectionHarness {
        let coordinator: ScreenshotCollectionView.Coordinator
        let collectionView: NSCollectionView
        let scrollView: NSScrollView
        private let collectionLayout: ScreenshotCollectionLayout
        private let window: NSWindow

        init(parent: ScreenshotCollectionView) {
            coordinator = parent.makeCoordinator()
            collectionLayout = ScreenshotCollectionLayout()
            collectionView = NSCollectionView()
            scrollView = NSScrollView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 360)
            )
            window = NSWindow(
                contentRect: scrollView.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            collectionView.frame = scrollView.contentView.bounds
            collectionView.autoresizingMask = [.width]
            collectionView.collectionViewLayout = collectionLayout
            collectionView.register(
                ScreenshotCollectionViewItem.self,
                forItemWithIdentifier: ScreenshotCollectionViewItem.reuseIdentifier
            )
            collectionView.delegate = coordinator
            scrollView.hasVerticalScroller = true
            scrollView.documentView = collectionView
            window.contentView = scrollView

            coordinator.installDataSource(on: collectionView)
            update(parent: parent)
        }

        func update(parent: ScreenshotCollectionView) {
            coordinator.update(parent: parent, collectionView: collectionView, layout: collectionLayout)
            layoutViews()
        }

        func layoutViews() {
            collectionLayout.invalidateLayout()
            window.contentView?.layoutSubtreeIfNeeded()
            collectionView.layoutSubtreeIfNeeded()
        }

        func scroll(toY y: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    @MainActor
    private final class SelectionBox {
        var value: Set<UUID>
        var isSelecting: Bool

        init(_ value: Set<UUID>) {
            self.value = value
            isSelecting = !value.isEmpty
        }
    }

    @MainActor
    private final class CollectionActionRecorder {
        var openedScreenshot: MeetingScreenshotRecord?
        var downloadedScreenshot: MeetingScreenshotRecord?
        var deletedScreenshot: MeetingScreenshotRecord?
    }
#endif
