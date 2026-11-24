#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct MainSidebarAccountMenuTests {
        @Test(arguments: ["localOnly", "localWithServer"])
        func addingAccountsAndBottomActionsFollowTheSelectedAccount(account: String) throws {
            let suite = "AccountMenuActions-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(generalDefaults: defaults)
            let server = makeConnection(origin: "https://server.example.com", isCloud: false)
            let hasServer = account == "localWithServer"
            var actions: [String] = []
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: hasServer ? [server] : [],
                accountSelection: .init(connectionID: nil, isLocal: true),
                onOpenSettings: { _ in Issue.record("Unexpected settings action") },
                onSelectAccount: { _ in Issue.record("Unexpected account switch") },
                onAddAccount: { actions.append("add") },
                onAccountAction: { actions.append("account") },
                onShowUnprocessedRecordings: { actions.append("recordings") },
                settings: settings
            )
            #expect(coordinator.showsAddAccount == hasServer)
            let showsBottom = account == "localOnly"
            #expect(coordinator.showsAccountAction == showsBottom)
            if coordinator.showsAddAccount {
                // A Dahlia account's row is disabled, so selection skips it.
                for _ in 0 ..< coordinator.menuOffset - 1 {
                    coordinator.moveSelection(1)
                }
                coordinator.activateSelection()
                #expect(actions == ["add"])
                actions.removeAll()
            }
            // Up from the start selects the last visible row; hidden Sign In must not remain reachable.
            coordinator.moveSelection(-1)
            coordinator.activateSelection()
            #expect(actions == [showsBottom ? "account" : "recordings"])
        }

        @Test(arguments: [false, true])
        func menuButtonFollowsTheFootersDisabledState(disabled: Bool) throws {
            // The footer is disabled while recording; the AppKit button must not open the account menu then.
            let host = NSHostingView(rootView: MainSidebarAccountMenuButton(
                connections: [],
                currentConnectionID: nil,
                isLocalAccount: true,
                onOpenSettings: { _ in },
                onSelectAccount: { _ in },
                onAccountAction: {},
                onShowUnprocessedRecordings: {}
            ).disabled(disabled))
            host.frame = NSRect(x: 0, y: 0, width: 240, height: 44)
            host.layoutSubtreeIfNeeded()

            func button(in view: NSView) -> MainSidebarAccountButton? {
                (view as? MainSidebarAccountButton) ?? view.subviews.lazy.compactMap(button(in:)).first
            }
            #expect(try #require(button(in: host)).isEnabled == !disabled)
        }

        @Test
        func panelWidthIncludesItsPadding() {
            let panel = MainSidebarAccountMenuPanel(width: 180) {
                Color.clear.frame(height: 30)
            }
            let hostingView = NSHostingView(rootView: panel.fixedSize())

            #expect(hostingView.fittingSize.width == 180)
        }

        @Test
        func eachFooterLineEndsInAnEllipsisInsteadOfWrapping() throws {
            let title = MainSidebarAccountMenuButton.footerTitle(
                accountName: L10n.unityGateway,
                syncSummary: "dbc-a5d4177a-49dc.cloud.databricks.com"
            )
            let hostLocation = (title.string as NSString).range(of: "dbc-").location
            let style = try #require(title.attribute(.paragraphStyle, at: hostLocation, effectiveRange: nil) as? NSParagraphStyle)
            // Wrapping broke the host at its hyphen into a line the footer has no room for.
            #expect(style.lineBreakMode == .byTruncatingTail)
        }

        @Test
        func footerTitleShowsOnlyTheAccountWithoutSyncProgress() {
            let title = MainSidebarAccountMenuButton.footerTitle(
                accountName: "Kazuki Matsuda"
            )

            #expect(title.string == "Kazuki Matsuda")
            #expect(!title.string.contains("\n"))
            #expect(!title.string.contains("\u{FFFC}"))

            let accountRange = (title.string as NSString).range(of: "Kazuki Matsuda")
            let accountFont = title.attribute(.font, at: accountRange.location, effectiveRange: nil) as? NSFont
            let paragraphStyle = title.attribute(
                .paragraphStyle,
                at: accountRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            #expect(accountFont?.pointSize == 14)
            #expect(paragraphStyle?.firstLineHeadIndent == 6)
            #expect(paragraphStyle?.headIndent == 6)
        }

        @Test
        func footerAnimatedIconIsDecorative() throws {
            let button = MainSidebarAccountButton(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            let icon = try #require(button.subviews.compactMap { $0 as? NSImageView }.first)
            button.image = try #require(NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil))
            button.imagePosition = .imageOnly
            button.layoutSubtreeIfNeeded()

            #expect(!icon.isAccessibilityElement())
            #expect(icon.frame != .zero)
            #expect(icon.hitTest(NSPoint(x: icon.frame.midX, y: icon.frame.midY)) == nil)
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
        func keyboardSelectionSkipsDahliaAccountsBecauseTheyOwnNoWorkspace() {
            let connection = makeConnection(origin: "https://used.example.com", isCloud: false)
            var selected: [UUID?] = []
            var addedAccounts = 0
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: [connection],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: nil,
                    isLocal: true
                ),
                onOpenSettings: { _ in },
                onSelectAccount: { selected.append($0?.id) },
                onAddAccount: { addedAccounts += 1 },
                onAccountAction: {},
                onShowUnprocessedRecordings: {}
            )

            // The rows are the Dahlia account, the app's account, then Add Account; the first is skipped.
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()

            #expect(addedAccounts == 1)
            #expect(selected.isEmpty)
        }

        @Test
        func keyboardMenuKeepsSettingsAndAccountActionsWithoutWorkspaceItems() {
            var openedCategories: [SettingsCategory?] = []
            var selectedAccount = false
            var accountActions = 0
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: [],
                accountSelection: .init(connectionID: nil, isLocal: true),
                onOpenSettings: { openedCategories.append($0) },
                onSelectAccount: { _ in selectedAccount = true },
                onAccountAction: { accountActions += 1 },
                onShowUnprocessedRecordings: {}
            )

            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(!selectedAccount)

            for _ in 0 ..< 4 {
                coordinator.moveSelection(1)
            }
            coordinator.activateSelection()
            #expect(openedCategories == [nil])

            coordinator.moveSelection(-1)
            coordinator.activateSelection()
            #expect(accountActions == 1)

        }

        @Test
        func keyboardOpensUnprocessedRecordingsAndDismissesMenu() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            window.contentView?.addSubview(button)
            let connections: [DahliaAccountConnection] = []
            var openedRecordings = 0
            var menuWasDismissed = false
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: connections,
                accountSelection: .init(
                    connectionID: connections.first?.id,
                    isLocal: connections.isEmpty
                ),
                onOpenSettings: { _ in Issue.record("Opened Settings instead of unprocessed recordings") },
                onSelectAccount: { _ in Issue.record("Switched accounts instead of opening unprocessed recordings") },
                onAccountAction: { Issue.record("Performed account action instead of opening unprocessed recordings") },
                unprocessedRecordingCount: 3,
                onShowUnprocessedRecordings: {
                    openedRecordings += 1
                    menuWasDismissed = window.childWindows?.isEmpty ?? true
                }
            )
            coordinator.button = button
            defer {
                coordinator.dismissMenu()
                window.close()
            }
            coordinator.toggleMenu()
            #expect(window.childWindows?.isEmpty == false)

            for _ in 0 ... coordinator.menuOffset + 3 {
                coordinator.moveSelection(1)
            }
            coordinator.activateSelection()

            #expect(openedRecordings == 1)
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
            let connections: [DahliaAccountConnection] = []
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: connections,
                accountSelection: .init(
                    connectionID: connections.first?.id, isLocal: connections.isEmpty
                ),
                onOpenSettings: { _ in Issue.record("Opened Settings") },
                onSelectAccount: { _ in Issue.record("Switched accounts") },
                onAccountAction: { Issue.record("Performed account action") },
                onShowUnprocessedRecordings: {},
                settings: settings
            )
            coordinator.button = button
            defer {
                coordinator.dismissMenu()
                window.close()
            }

            for choice in [AppAppearance.dark, .light, .system] {
                coordinator.toggleMenu()
                for _ in 0 ... coordinator.menuOffset + 1 {
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

        private func makeConnection(origin: String, isCloud: Bool) -> DahliaAccountConnection {
            DahliaAccountConnection(
                record: DahliaAccountConnectionRecord(
                    id: .v7(),
                    origin: origin,
                    clientID: "desktop-client",
                    createdAt: .now
                ),
                account: DahliaCloudAccount(id: origin, name: origin, email: nil),
                isCloud: isCloud
            )
        }

    }
#endif
