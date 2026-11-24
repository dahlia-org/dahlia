#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct MainSidebarAccountMenuTests {
        @Test
        func panelWidthIncludesItsPadding() {
            let panel = MainSidebarAccountMenuPanel(width: 180) {
                Color.clear.frame(height: 30)
            }
            let hostingView = NSHostingView(rootView: panel.fixedSize())

            #expect(hostingView.fittingSize.width == 180)
        }

        @Test
        func submenuAppearsOnRightAndFlipsLeftAtTheScreenEdge() {
            let panelSize = CGSize(width: 180, height: 100)
            let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

            let fitsOnRight = MainSidebarAccountMenuLayout.submenuOrigin(
                panelSize: panelSize,
                mainPanelFrame: CGRect(x: 100, y: 200, width: 180, height: 120),
                screenFrame: screenFrame
            )
            let flipsToLeft = MainSidebarAccountMenuLayout.submenuOrigin(
                panelSize: panelSize,
                mainPanelFrame: CGRect(x: 800, y: 200, width: 180, height: 120),
                screenFrame: screenFrame
            )

            #expect(fitsOnRight == CGPoint(x: 286, y: 220))
            #expect(flipsToLeft == CGPoint(x: 614, y: 220))
        }

        @Test
        func submenuAlignsWithTheHoveredRootRow() {
            let mainPanelFrame = CGRect(x: 100, y: 200, width: 180, height: 120)
            let origin = MainSidebarAccountMenuLayout.submenuOrigin(
                panelSize: CGSize(width: 180, height: 100),
                mainPanelFrame: mainPanelFrame,
                screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                anchorY: MainSidebarAccountMenuLayout.submenuAnchorY(rowMinY: 38, mainPanelFrame: mainPanelFrame)
            )

            #expect(origin == CGPoint(x: 286, y: 182))
        }

        @Test
        func mainMenuAlignsItsLeftEdgeWithTheButton() {
            let origin = MainSidebarAccountMenuLayout.mainMenuOrigin(
                panelSize: CGSize(width: 180, height: 100),
                buttonFrame: CGRect(x: 400, y: 100, width: 30, height: 30),
                screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            )

            #expect(origin == CGPoint(x: 400, y: 136))
        }

        @Test
        func selectsScreenContainingButtonInsteadOfWindowScreen() {
            let screenIndex = MainSidebarAccountMenuLayout.screenIndex(
                containing: CGRect(x: 1050, y: 100, width: 120, height: 30),
                screenFrames: [
                    CGRect(x: 0, y: 0, width: 1000, height: 800),
                    CGRect(x: 1000, y: 0, width: 1200, height: 900),
                ]
            )

            #expect(screenIndex == 1)
        }

        @Test
        func keyboardSelectionSkipsDisabledItemsAndWraps() {
            let first = MainSidebarAccountMenuNavigationState.nextEnabledIndex(
                from: nil,
                direction: 1,
                count: 3,
                isEnabled: { $0 != 0 }
            )
            let wrapped = MainSidebarAccountMenuNavigationState.nextEnabledIndex(
                from: 2,
                direction: 1,
                count: 3,
                isEnabled: { $0 != 0 }
            )

            #expect(first == 1)
            #expect(wrapped == 1)
        }

        @Test
        func typeAheadSelectionMatchesPrefixAndSkipsDisabledItems() {
            let match = MainSidebarAccountMenuNavigationState.firstEnabledIndex(
                matching: "pri",
                titles: ["Primary", "Private", "Project"],
                isEnabled: { $0 != 0 }
            )

            #expect(match == 1)
        }

        @Test
        func navigationStateKeepsSelectionSemantics() {
            let navigation = MainSidebarAccountMenuNavigationState()

            navigation.selectRoot(2)
            #expect(navigation.activeMenu == .root)
            #expect(navigation.rootSelection == 2)
            #expect(navigation.submenuSelection == nil)

            navigation.showSubmenu(.languages)
            navigation.selectSubmenu(1)
            #expect(navigation.activeMenu == .languages)
            #expect(navigation.submenuSelection == 1)

            navigation.reset()
            #expect(navigation.activeMenu == .root)
            #expect(navigation.rootSelection == nil)
            #expect(navigation.submenuSelection == nil)
        }

        @Test
        func optionOnlyTextInputDoesNotPassThroughMenu() {
            #expect(!MainSidebarAccountMenuCoordinator.shouldPassThroughKeyEvent(modifierFlags: [.option]))
            #expect(MainSidebarAccountMenuCoordinator.shouldPassThroughKeyEvent(modifierFlags: [.command, .option]))
            #expect(MainSidebarAccountMenuCoordinator.shouldPassThroughKeyEvent(modifierFlags: [.control]))
        }

        @Test
        func keyboardOpensSettingsAndDismissesMenu() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            window.contentView?.addSubview(button)
            var openedSettings = 0
            var menuWasDismissed = false
            let coordinator = MainSidebarAccountMenuCoordinator(onOpenSettings: {
                openedSettings += 1
                menuWasDismissed = window.childWindows?.isEmpty ?? true
            })
            coordinator.button = button
            defer {
                coordinator.dismissMenu()
                window.close()
            }
            coordinator.toggleMenu()
            #expect(window.childWindows?.isEmpty == false)

            // Up from no selection wraps to the last row, Settings.
            coordinator.moveSelection(-1)
            coordinator.activateSelection()

            #expect(openedSettings == 1)
            #expect(menuWasDismissed)
        }

        @Test
        func appearanceMenuSupportsKeyboardSelectionAndRestoresTheSavedChoice() throws {
            let suiteName = "MainSidebarAccountMenuTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            let application = NSApplication.shared
            let originalAppearance = application.appearance
            defer {
                application.appearance = originalAppearance
                defaults.removePersistentDomain(forName: suiteName)
            }
            let settings = AppSettings(appearanceDefaults: defaults)
            #expect(settings.appAppearance == .system)
            settings.applyAppearance()
            #expect(application.appearance == nil)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            window.contentView?.addSubview(button)
            let coordinator = MainSidebarAccountMenuCoordinator(
                onOpenSettings: { Issue.record("Opened Settings") },
                settings: settings
            )
            coordinator.button = button
            defer {
                coordinator.dismissMenu()
                window.close()
            }

            for choice in [AppAppearance.dark, .light, .system] {
                coordinator.toggleMenu()
                for _ in 0 ... MainSidebarAccountRootMenuView.Item.appearance.rawValue {
                    coordinator.moveSelection(1)
                }
                coordinator.openSelectedSubmenu()
                #expect(window.childWindows?.count == 2)
                #expect(!coordinator.selectTypeAheadMatch(for: settings.appAppearance.displayName))
                coordinator.moveSelection(1)
                if choice == .dark {
                    coordinator.moveSelection(1)
                } else {
                    #expect(coordinator.selectTypeAheadMatch(for: choice.displayName))
                }
                coordinator.activateSelection()
                #expect(settings.appAppearance == choice)
                #expect(application.appearance?.name == choice.appearance?.name)
                #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                    == application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
                #expect(window.childWindows?.isEmpty == true)
                let restored = AppSettings(appearanceDefaults: defaults)
                #expect(restored.appAppearance == choice)
                restored.applyAppearance()
                #expect(application.appearance?.name == choice.appearance?.name)
            }

            defaults.set("unknown", forKey: AppAppearance.userDefaultsKey)
            #expect(AppSettings(appearanceDefaults: defaults).appAppearance == .system)
        }
    }
#endif
