#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct ProjectCatalogObservationTrackerTests {
        @Test
        func newestObservationTokenIsCurrent() {
            var tracker = ProjectCatalogObservationTracker()

            let first = tracker.beginObservation()
            let second = tracker.beginObservation()

            #expect(!tracker.isCurrent(first))
            #expect(tracker.isCurrent(second))
        }

        @Test
        func invalidationRejectsQueuedCallbacks() {
            var tracker = ProjectCatalogObservationTracker()
            let token = tracker.beginObservation()

            tracker.invalidate()

            #expect(!tracker.isCurrent(token))
        }
    }
#endif
