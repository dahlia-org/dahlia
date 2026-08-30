import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct ScreenshotCollectionIncrementalUpdateTests {
        @Test
        func appendOnlyIdentifierUpdatesStayIncremental() {
            let first = UUID.v7()
            let second = UUID.v7()
            let third = UUID.v7()

            #expect(
                ScreenshotCollectionView.Coordinator.identifierUpdate(
                    currentIDs: [first],
                    newIDs: [first, second, third]
                ) == .append([second, third])
            )
            #expect(
                ScreenshotCollectionView.Coordinator.identifierUpdate(
                    currentIDs: [first, second],
                    newIDs: [second]
                ) == .reset
            )
            #expect(
                ScreenshotCollectionView.Coordinator.identifierUpdate(
                    currentIDs: [first],
                    newIDs: [first]
                ) == .unchanged
            )
        }

        @Test
        func snapshotUpdatesOnlyWhenIdentifiersChange() {
            let first = UUID.v7()
            let second = UUID.v7()
            let otherMeeting = UUID.v7()

            #expect(ScreenshotCollectionView.Coordinator.identifierUpdate(currentIDs: [], newIDs: [first]) == .append([first]))
            #expect(ScreenshotCollectionView.Coordinator.identifierUpdate(currentIDs: [first], newIDs: [first]) == .unchanged)
            #expect(
                ScreenshotCollectionView.Coordinator.identifierUpdate(
                    currentIDs: [first],
                    newIDs: [first, second]
                ) == .append([second])
            )
            #expect(ScreenshotCollectionView.Coordinator.identifierUpdate(currentIDs: [first, second], newIDs: [second]) == .reset)
            #expect(ScreenshotCollectionView.Coordinator.identifierUpdate(currentIDs: [first, second], newIDs: [otherMeeting]) == .reset)
        }

        @Test
        func metadataRebuildUsesContentRevisionForUnchangedIdentifiers() {
            let first = UUID.v7()

            #expect(!ScreenshotCollectionView.Coordinator.shouldRebuildMetadata(
                identifierUpdate: .unchanged,
                currentContentRevision: 4,
                newContentRevision: 4
            ))
            #expect(ScreenshotCollectionView.Coordinator.shouldRebuildMetadata(
                identifierUpdate: .unchanged,
                currentContentRevision: 4,
                newContentRevision: 5
            ))
            #expect(ScreenshotCollectionView.Coordinator.shouldRebuildMetadata(
                identifierUpdate: .unchanged,
                currentContentRevision: nil,
                newContentRevision: nil
            ))
            #expect(ScreenshotCollectionView.Coordinator.shouldRebuildMetadata(
                identifierUpdate: .append([first]),
                currentContentRevision: 4,
                newContentRevision: 4
            ))
        }
    }
#endif
