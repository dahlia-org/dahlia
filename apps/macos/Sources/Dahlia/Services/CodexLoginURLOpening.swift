import Foundation

@MainActor
protocol CodexLoginURLOpening {
    func open(_ url: URL) -> Bool
}
