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
}
#endif
