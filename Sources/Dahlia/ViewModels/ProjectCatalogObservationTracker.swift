struct ProjectCatalogObservationTracker {
    private(set) var generation: UInt = 0

    mutating func beginObservation() -> UInt {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ candidate: UInt) -> Bool {
        candidate == generation
    }
}
