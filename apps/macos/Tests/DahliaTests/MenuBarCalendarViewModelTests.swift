import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MenuBarCalendarViewModelTests {
        @Test
        func requiresAtLeastOneSourceAndEveryEnabledSourceToBeLoaded() {
            #expect(!loadedSources([], google: true, macOS: true))
            #expect(!loadedSources([.google], google: false, macOS: true))
            #expect(loadedSources([.google], google: true, macOS: false))
            #expect(!loadedSources([.google, .macOS], google: true, macOS: false))
            #expect(loadedSources([.google, .macOS], google: true, macOS: true))
        }

        private func loadedSources(
            _ enabledSources: Set<CalendarSource>,
            google: Bool,
            macOS: Bool
        ) -> Bool {
            var loadedSources: Set<CalendarSource> = []
            if google { loadedSources.insert(.google) }
            if macOS { loadedSources.insert(.macOS) }
            return CalendarSourceCoordinator.allSourcesAreLoaded(
                enabledSources,
                loadedSources: loadedSources
            )
        }
    }
#endif
