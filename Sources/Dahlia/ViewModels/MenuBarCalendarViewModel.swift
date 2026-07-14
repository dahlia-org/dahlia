import Foundation
import Observation

@MainActor
@Observable
final class MenuBarCalendarViewModel {
    private(set) var currentDate = Date.now

    private let settings: AppSettings
    private let googleCalendarStore: GoogleCalendarStore
    private let macCalendarStore: MacCalendarStore
    private var isRefreshLoopRunning = false

    init(
        settings: AppSettings = .shared,
        googleCalendarStore: GoogleCalendarStore = .shared,
        macCalendarStore: MacCalendarStore = .shared
    ) {
        self.settings = settings
        self.googleCalendarStore = googleCalendarStore
        self.macCalendarStore = macCalendarStore
    }

    func runRefreshLoop() async {
        guard !isRefreshLoopRunning else { return }
        isRefreshLoopRunning = true
        defer { isRefreshLoopRunning = false }

        while !Task.isCancelled {
            currentDate = .now
            if settings.menuBarCalendarEnabled {
                await refreshEnabledSources()
            }

            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }

    private func refreshEnabledSources() async {
        if settings.isCalendarSourceEnabled(.google) {
            await googleCalendarStore.refreshIfNeeded()
        }
        if settings.isCalendarSourceEnabled(.macOS) {
            await macCalendarStore.refreshIfNeeded()
        }
    }
}
