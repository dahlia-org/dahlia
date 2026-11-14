#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct MainSidebarAccountMenuTests {
        @Test(arguments: ["localOnly", "localWithDatabricks", "localWithServer", "databricks", "server"], [false, true])
        func addingAccountsAndBottomActionsFollowTheSelectedAccount(account: String, hidden: Bool) throws {
            let suite = "AccountMenuActions-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(generalDefaults: defaults)
            settings.hideLocalAccount = hidden
            let server = makeConnection(origin: "https://server.example.com", isCloud: false)
            let gateway = DatabricksConnection(id: .v7(), host: "https://one.example.com")
            let hasServer = account == "server" || account == "localWithServer"
            let hasDatabricks = account == "databricks" || account == "localWithDatabricks"
            var actions: [String] = []
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: hasServer ? [server] : [],
                accountSelection: .init(
                    connectionID: account == "server" ? server.id : nil,
                    isLocal: account != "server",
                    databricksAccounts: hasDatabricks ? [gateway] : [],
                    currentDatabricksID: account == "databricks" ? gateway.id : nil
                ),
                onOpenSettings: { _ in Issue.record("Unexpected settings action") },
                onSelectAccount: { _ in Issue.record("Unexpected account switch") },
                onAddAccount: { actions.append("add") },
                onAccountAction: { actions.append("account") },
                onShowUnprocessedRecordings: { actions.append("recordings") },
                settings: settings
            )
            #expect(coordinator.showsAddAccount == (hasServer || hasDatabricks))
            let showsBottom = account == "localOnly" || account == "server" || account == "databricks"
            #expect(coordinator.showsAccountAction == showsBottom)
            if coordinator.showsAddAccount {
                for _ in 0 ..< coordinator.menuOffset {
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
        func hiddenLocalAccountKeepsKeyboardAccountAndSettingsActionsAligned(hidden: Bool) throws {
            let suite = "AccountMenuVisibility-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(generalDefaults: defaults)
            settings.hideLocalAccount = hidden
            let gateway = DatabricksConnection(id: .v7(), host: "https://one.example.com")
            let current = DatabricksConnection(id: .v7(), host: "https://current.example.com")
            var selections: [String] = []
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: [],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: nil, isLocal: true, databricksAccounts: [gateway, current], currentDatabricksID: current.id
                ),
                onOpenSettings: { _ in selections.append("settings") },
                onSelectAccount: { _ in selections.append("local") },
                onSelectDatabricksAccount: { id in
                    #expect(id == gateway.id)
                    selections.append("databricks")
                },
                onAccountAction: {},
                onShowUnprocessedRecordings: {},
                settings: settings
            )
            #expect(coordinator.menuOffset == (hidden ? 3 : 4))
            func activate(row: Int) {
                for _ in 0 ... row {
                    coordinator.moveSelection(1)
                }
                coordinator.activateSelection()
            }
            activate(row: 0)
            activate(row: coordinator.menuOffset + 2)
            #expect(selections == [hidden ? "databricks" : "local", "settings"])
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
        func accountDetailsFitTheMenuAndSyncProgressAppearsInTheFooter() throws {
            let pending = WorkspaceSyncProgress(
                id: UUID(),
                name: "Work Workspace",
                state: .pending,
                phase: .attachments,
                issues: [],
                allowsCanonicalEdits: true,
                retryAt: nil,
                retryErrorCode: nil,
                discardImpact: nil,
                recordingArchiveFailures: [],
                meetings: 0,
                files: 2400,
                attachments: 2400,
                other: 0
            )
            let progress = AccountSyncProgress(workspaces: [pending])
            let footer = MainSidebarAccountMenuButton.footerTitle(accountName: "Account", syncSummary: progress.summary)
            #expect(footer.string.contains(progress.summary))
            #expect(footer.string == "Account\n" + progress.summary)
            #expect(!footer.string.contains(pending.name))
            let connection = makeConnection(origin: "https://server.example.com", isCloud: false)
            let menu = NSHostingView(rootView: MainSidebarAccountMenuPanel(width: 320) {
                SyncProgressView(connection: connection, navigation: MainSidebarAccountMenuNavigationState())
            }.fixedSize())
            #expect(menu.fittingSize.width == 320)
            #expect(menu.fittingSize.height > 40 && menu.fittingSize.height <= 432)

            let rows = [
                WorkspaceSyncProgress(
                    id: UUID(),
                    name: "Preparing",
                    state: .pending,
                    phase: .preparing,
                    issues: [],
                    allowsCanonicalEdits: true,
                    retryAt: nil,
                    retryErrorCode: nil,
                    discardImpact: nil,
                    recordingArchiveFailures: [],
                    meetings: 0,
                    files: 0,
                    attachments: 0,
                    other: 0
                ),
                pending,
                WorkspaceSyncProgress(
                    id: UUID(),
                    name: "Needs attention",
                    state: .blocked(.validation),
                    phase: .attention,
                    issues: [.init(
                        source: .queue(.validation),
                        status: 422,
                        code: "invalid_sync_operation",
                        target: nil
                    )],
                    allowsCanonicalEdits: true,
                    retryAt: nil,
                    retryErrorCode: nil,
                    discardImpact: .init(
                        transactions: 1,
                        operations: 1,
                        records: 1,
                        localBodies: 0,
                        meetings: 0,
                        lastTransactionId: .v7(),
                        hasConfirmedWorkspace: true
                    ),
                    recordingArchiveFailures: [],
                    meetings: 2,
                    files: 8,
                    attachments: 8,
                    other: 0
                ),
            ]
            let preview = MainSidebarAccountMenuPanel(width: 320) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.syncProgress).font(.headline)
                    ForEach(rows) { WorkspaceSyncProgressView(progress: $0) }
                }.padding(12)
            }
            let host = NSHostingView(rootView: preview.fixedSize())
            #expect(host.fittingSize.width == 320)
            if let path = ProcessInfo.processInfo.environment["DAHLIA_SYNC_PROGRESS_SNAPSHOT"] {
                let renderer = ImageRenderer(content: preview.fixedSize())
                renderer.scale = 2
                let data = try #require(renderer.nsImage?.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: data))
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
            }
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
        func accountSyncIconsAnimateOnlyWhileSyncing() {
            let activePhases: [WorkspaceSyncProgress.Phase] = [.preparing, .text, .attachments, .fetching]
            let staticPhases: [WorkspaceSyncProgress.Phase] = [.retrying, .attention, .synced]

            #expect(activePhases.allSatisfy { makeSyncProgress(phase: $0).isSyncing })
            #expect(staticPhases.allSatisfy { !makeSyncProgress(phase: $0).isSyncing })
            #expect(!AccountSyncProgress(workspaces: []).isSyncing)
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
        func accountWorkspacesUseCreationOrderAndExcludeOtherAccounts() {
            let connectionID = UUID.v7()
            let first = makeWorkspace(name: "First", accountConnectionID: connectionID, createdAt: .distantPast)
            let local = makeWorkspace(name: "Local", accountConnectionID: nil)
            let second = makeWorkspace(name: "Second", accountConnectionID: connectionID, createdAt: .now)

            #expect(MainSidebarFooterView.workspaces([second, local, first], linkedTo: connectionID) == [first, second])
            #expect(MainSidebarFooterView.workspaces([first, local, second], linkedTo: nil) == [local])
            #expect(MainSidebarFooterView.workspaceToSelect(
                from: [first, local, second],
                currentWorkspace: local,
                connectionID: connectionID
            ) == first)
            #expect(MainSidebarFooterView.workspaceToSelect(
                from: [first, local, second],
                currentWorkspace: first,
                connectionID: connectionID
            ) == nil)
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

            navigation.showSubmenu(.accountDetails)
            navigation.publishAccountDetailError("Failed", for: navigation.accountDetailPresentationID)
            navigation.selectSubmenu(1)
            #expect(navigation.activeMenu == .accountDetails)
            #expect(navigation.submenuSelection == 1)

            navigation.reset()
            #expect(navigation.activeMenu == .root)
            #expect(navigation.rootSelection == nil)
            #expect(navigation.submenuSelection == nil)
            #expect(navigation.accountDetailError == nil)
        }

        @Test
        func staleAccountDetailErrorsAreDiscarded() throws {
            let navigation = MainSidebarAccountMenuNavigationState()
            navigation.showSubmenu(.accountDetails)
            let stalePresentationID = try #require(navigation.accountDetailPresentationID)

            navigation.showSubmenu(.accountDetails)
            navigation.publishAccountDetailError("Stale", for: stalePresentationID)
            #expect(navigation.accountDetailError == nil)

            navigation.publishAccountDetailError("Current", for: navigation.accountDetailPresentationID)
            #expect(navigation.accountDetailError == "Current")
        }

        @Test
        func optionOnlyTextInputDoesNotPassThroughMenu() {
            #expect(!MainSidebarAccountMenuCoordinator.shouldPassThroughKeyEvent(modifierFlags: [.option]))
            #expect(MainSidebarAccountMenuCoordinator.shouldPassThroughKeyEvent(modifierFlags: [.command, .option]))
            #expect(MainSidebarAccountMenuCoordinator.shouldPassThroughKeyEvent(modifierFlags: [.control]))
        }

        @Test
        func keyboardOpensTheSelectedAccountDetails() throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            window.contentView?.addSubview(button)
            let connections = [makeConnection(origin: "https://server.example.com", isCloud: false)]
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: connections,
                accountSelection: .init(connectionID: nil, isLocal: true),
                onOpenSettings: { _ in }, onSelectAccount: { _ in }, onAccountAction: {},
                onShowUnprocessedRecordings: {}
            )
            coordinator.button = button
            var openedURLs: [URL] = []
            coordinator.openURL = {
                openedURLs.append($0)
                return true
            }
            defer { coordinator.dismissMenu()
                window.close()
            }
            coordinator.toggleMenu()
            if let path = ProcessInfo.processInfo.environment["DAHLIA_ACCOUNT_MENU_SNAPSHOT"] {
                let content = try #require(window.childWindows?.first?.contentView)
                content.layoutSubtreeIfNeeded()
                let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
            }
            coordinator.moveSelection(1)
            coordinator.openSelectedSubmenu()
            let panel = try #require(window.childWindows?.last)
            #expect(!panel.canBecomeKey)
            #expect(panel.frame.width == 320)

            for keyCode: UInt16 in [36, 49, 76] {
                let characters = keyCode == 49 ? " " : "\r"
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
                ))
                #expect(coordinator.handleKeyDown(event) == nil)
            }
            #expect(openedURLs.map(\.absoluteString) == Array(repeating: connections[0].origin, count: 3))

            let shiftSpace = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
            ))
            #expect(coordinator.handleKeyDown(shiftSpace) == nil)
            #expect(openedURLs.count == 3)
        }

        @Test
        func keyboardAccountRowsSwitchAccountsAndPerformAccountAction() {
            let cloud = makeConnection(origin: "https://cloud.example.com", isCloud: true)
            let server = makeConnection(origin: "https://server.example.com", isCloud: false)
            var selectedConnectionID: UUID?
            var didSelectAccount = false
            var didManageAccounts = false
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: [cloud, server],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: cloud.id,
                    isLocal: false
                ),
                onOpenSettings: { _ in },
                onSelectAccount: {
                    didSelectAccount = true
                    selectedConnectionID = $0?.id
                },
                onAccountAction: { didManageAccounts = true },
                onShowUnprocessedRecordings: {}
            )

            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(selectedConnectionID == server.id)

            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(didSelectAccount)
            #expect(selectedConnectionID == nil)

            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(selectedConnectionID == nil)

            coordinator.moveSelection(-1)
            coordinator.activateSelection()
            #expect(didManageAccounts)
        }

        @Test
        func databricksFooterShowsUnityGatewayOverTheHostAndTheMenuNamesTheHost() {
            var connection = DatabricksConnection(id: UUID(), host: "https://dbc-1.cloud.databricks.com")
            #expect(MainSidebarAccountMenuButton.databricksFooterLines(connection) == (L10n.unityGateway, "dbc-1.cloud.databricks.com"))
            #expect(L10n.unityGatewayHost(connection.hostName) == "Unity Gateway (dbc-1.cloud.databricks.com)")
            // The email no longer shows in the footer; the workspace settings' account picker still names it.
            connection.email = "me@example.com"
            #expect(MainSidebarAccountMenuButton.databricksFooterLines(connection) == (L10n.unityGateway, "dbc-1.cloud.databricks.com"))
            #expect(connection.accountLabel == "dbc-1 (me@example.com)")
            #expect(MainSidebarAccountMenuButton.databricksFooterLines(nil) == (L10n.databricks, nil))
        }

        @Test
        func localAndDatabricksAccountsListTheirOwnWorkspaces() {
            var local = WorkspaceRecord(id: .v7(), path: nil, name: "Local", createdAt: .distantPast, lastOpenedAt: .now)
            var databricks = WorkspaceRecord(
                id: .v7(), path: nil, name: "Databricks", createdAt: .now, lastOpenedAt: .now, databricksConnectionId: .v7()
            )
            #expect(MainSidebarFooterView.workspaces([databricks, local], linkedTo: nil) == [local])
            let account = databricks.databricksConnectionId
            #expect(MainSidebarFooterView.workspaces([databricks, local], linkedTo: nil, databricks: account) == [databricks])
            #expect(MainSidebarFooterView.workspaces([databricks, local], linkedTo: nil, databricks: .v7()).isEmpty)
            #expect(MainSidebarFooterView.workspaceToSelect(
                from: [local, databricks], currentWorkspace: local, connectionID: nil, databricks: account
            ) == databricks)
            #expect(MainSidebarFooterView.workspaceToSelect(from: [local, databricks], currentWorkspace: local, connectionID: nil) == nil)

            // The listed copy wins over an open workspace that has since moved to the Databricks account.
            let staleOpen = local
            local.databricksConnectionId = databricks.databricksConnectionId
            databricks.databricksConnectionId = nil
            #expect(MainSidebarFooterView.workspaceToSelect(
                from: [local, databricks], currentWorkspace: staleOpen, connectionID: nil
            ) == databricks)
        }

        @Test
        func keyboardSwitchesBetweenTheLocalAndDatabricksAccounts() {
            var selections: [String] = []
            let first = DatabricksConnection(id: UUID(), host: "https://one.example.com")
            let second = DatabricksConnection(id: UUID(), host: "https://two.example.com")
            func coordinator(current: UUID?) -> MainSidebarAccountMenuCoordinator {
                MainSidebarAccountMenuCoordinator(
                    connections: [],
                    accountSelection: MainSidebarAccountSelection(
                        connectionID: nil, isLocal: true,
                        databricksAccounts: [first, second], currentDatabricksID: current
                    ),
                    onOpenSettings: { _ in selections.append("settings") },
                    onSelectAccount: { selections.append($0 == nil ? "local" : "server") },
                    onSelectDatabricksAccount: { selections.append($0 == first.id ? "first" : "second") },
                    onAccountAction: {},
                    onShowUnprocessedRecordings: {}
                )
            }

            /// Each activation closes the menu, so every selection starts again from the first row.
            func activate(_ coordinator: MainSidebarAccountMenuCoordinator, row: Int) {
                for _ in 0 ... row {
                    coordinator.moveSelection(1)
                }
                coordinator.activateSelection()
            }
            let local = coordinator(current: nil)
            activate(local, row: 0)
            activate(local, row: 1)
            activate(local, row: 2)
            let databricks = coordinator(current: first.id)
            activate(databricks, row: 0)
            activate(databricks, row: 1)
            activate(databricks, row: databricks.menuOffset + 2)

            // Choosing the current account does nothing; the rows after the Databricks accounts keep their actions.
            #expect(selections == ["first", "second", "local", "settings"])
        }

        @Test
        func keyboardSelectionSkipsAccountsWithoutWorkspaces() {
            let unavailable = makeConnection(origin: "https://unused.example.com", isCloud: false, workspaceCount: 0)
            let available = makeConnection(origin: "https://used.example.com", isCloud: false)
            var selectedConnectionID: UUID?
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: [unavailable, available],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: nil,
                    isLocal: true
                ),
                onOpenSettings: { _ in },
                onSelectAccount: { selectedConnectionID = $0?.id },
                onAccountAction: {},
                onShowUnprocessedRecordings: {}
            )

            coordinator.moveSelection(1)
            coordinator.activateSelection()

            #expect(selectedConnectionID == available.id)
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

        @Test(arguments: ["local", "server", "databricks"])
        func keyboardOpensUnprocessedRecordingsAndDismissesMenu(account: String) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            window.contentView?.addSubview(button)
            let connections = account == "server" ? [makeConnection(origin: "https://server.example.com", isCloud: false)] : []
            let databricksAccounts = account == "databricks" ? [DatabricksConnection(id: .v7(), host: "https://dbc.example.com")] : []
            var openedRecordings = 0
            var menuWasDismissed = false
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: connections,
                accountSelection: .init(
                    connectionID: connections.first?.id,
                    isLocal: connections.isEmpty,
                    databricksAccounts: databricksAccounts,
                    currentDatabricksID: databricksAccounts.first?.id
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

        @Test(arguments: ["local", "server", "databricks"])
        func appearanceMenuSupportsKeyboardSelectionAndRestoresTheSavedChoice(account: String) throws {
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
            let connections = account == "server" ? [makeConnection(origin: "https://server.example.com", isCloud: false)] : []
            let databricksAccounts = account == "databricks" ? [DatabricksConnection(id: .v7(), host: "https://dbc.example.com")] : []
            let coordinator = MainSidebarAccountMenuCoordinator(
                connections: connections,
                accountSelection: .init(
                    connectionID: connections.first?.id, isLocal: connections.isEmpty,
                    databricksAccounts: databricksAccounts, currentDatabricksID: databricksAccounts.first?.id
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

        private func makeConnection(origin: String, isCloud: Bool, workspaceCount: Int = 1) -> DahliaAccountConnection {
            DahliaAccountConnection(
                record: DahliaAccountConnectionRecord(
                    id: .v7(),
                    origin: origin,
                    clientID: "desktop-client",
                    createdAt: .now
                ),
                account: DahliaCloudAccount(id: origin, name: origin, email: nil),
                isCloud: isCloud,
                workspaceCount: workspaceCount
            )
        }

        private func makeSyncProgress(phase: WorkspaceSyncProgress.Phase) -> AccountSyncProgress {
            AccountSyncProgress(workspaces: [WorkspaceSyncProgress(
                id: .v7(),
                name: "Workspace",
                state: phase == .synced ? .synced : .pending,
                phase: phase,
                issues: [],
                allowsCanonicalEdits: true,
                retryAt: nil,
                retryErrorCode: nil,
                discardImpact: nil,
                recordingArchiveFailures: [],
                meetings: 0,
                files: 0,
                attachments: 0,
                other: 0
            )])
        }

        private func makeWorkspace(
            name: String,
            accountConnectionID: UUID?,
            createdAt: Date = .now
        ) -> WorkspaceRecord {
            WorkspaceRecord(
                id: .v7(),
                path: "/tmp/\(name)",
                name: name,
                createdAt: createdAt,
                lastOpenedAt: .now,
                accountConnectionId: accountConnectionID
            )
        }
    }
#endif
