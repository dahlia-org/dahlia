#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    extension MainWindowNavigationTests {
        @Test
        func sidebarUsesDefaultWidthWhenNoWidthIsStored() throws {
            let (defaults, suiteName) = try temporarySidebarDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)

            #expect(navigation.sidebarWidth == MainSidebarLayout.defaultWidth)
        }

        @Test
        func sidebarRestoresStoredWidth() throws {
            let (defaults, suiteName) = try temporarySidebarDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(348, forKey: MainSidebarLayout.widthDefaultsKey)

            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)

            #expect(navigation.sidebarWidth == 348)
        }

        @Test
        func sidebarClampsStoredWidthToSupportedRange() throws {
            let (defaults, suiteName) = try temporarySidebarDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(100, forKey: MainSidebarLayout.widthDefaultsKey)

            var navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)

            #expect(navigation.sidebarWidth == MainSidebarLayout.minimumWidth)
            #expect(defaults.double(forKey: MainSidebarLayout.widthDefaultsKey) == Double(MainSidebarLayout.minimumWidth))

            defaults.set(800, forKey: MainSidebarLayout.widthDefaultsKey)
            navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)

            #expect(navigation.sidebarWidth == MainSidebarLayout.maximumWidth)
            #expect(defaults.double(forKey: MainSidebarLayout.widthDefaultsKey) == Double(MainSidebarLayout.maximumWidth))
        }

        @Test
        func sidebarWidthUpdatesArePersisted() throws {
            let (defaults, suiteName) = try temporarySidebarDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)

            navigation.updateSidebarWidth(360)

            #expect(navigation.sidebarWidth == 360)
            #expect(defaults.double(forKey: MainSidebarLayout.widthDefaultsKey) == 360)
            let restoredNavigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)
            #expect(restoredNavigation.sidebarWidth == 360)
        }

        @Test
        func chatSidebarUsesDefaultWidthWhenNoWidthIsStored() throws {
            let (defaults, suiteName) = try temporarySidebarDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)

            #expect(navigation.chatSidebarWidth == MainChatSidebarLayout.defaultWidth)
        }

        @Test
        func chatSidebarClampsAndPersistsWidth() throws {
            let (defaults, suiteName) = try temporarySidebarDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(100, forKey: MainChatSidebarLayout.widthDefaultsKey)

            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)
            #expect(navigation.chatSidebarWidth == MainChatSidebarLayout.minimumWidth)

            navigation.updateChatSidebarWidth(800)
            #expect(navigation.chatSidebarWidth == MainChatSidebarLayout.maximumWidth)
            #expect(
                defaults.double(forKey: MainChatSidebarLayout.widthDefaultsKey)
                    == Double(MainChatSidebarLayout.maximumWidth)
            )
        }

        @Test
        func chatToolbarContentTracksSidebarWidthWithConsistentInsets() {
        #expect(MainChatSidebarLayout.toolbarContentWidth(for: 320) == 304)
        #expect(MainChatSidebarLayout.toolbarContentWidth(for: 520) == 504)
        }

        private func temporarySidebarDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
            let suiteName = "MainWindowNavigationTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            return (defaults, suiteName)
        }
    }
#endif
