enum SearchMode: CaseIterable, Sendable {
    case simple
    case advanced
    case neural

    var isAvailable: Bool {
        self != .neural
    }
}
