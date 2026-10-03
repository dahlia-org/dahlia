struct MeetingCalendarPopupScheduleState {
    private(set) var generation: UInt64 = 0
    private(set) var scheduledIdentifiers = Set<String>()
    private(set) var deliveredIdentifiers = Set<String>()

    mutating func replace(with identifiers: Set<String>) -> UInt64 {
        generation &+= 1
        scheduledIdentifiers = identifiers
        deliveredIdentifiers.formIntersection(identifiers)
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        scheduledIdentifiers.removeAll()
        deliveredIdentifiers.removeAll()
    }

    mutating func claim(_ identifier: String, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration,
              scheduledIdentifiers.contains(identifier)
        else { return false }
        return deliveredIdentifiers.insert(identifier).inserted
    }
}
