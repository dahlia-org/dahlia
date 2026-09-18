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
            let footer = MainSidebarAccountMenuButton.footerTitle(accountName: "Account", workspaceName: pending.name, syncSummary: progress.summary)
            #expect(footer.string.contains(progress.summary))
            #expect(footer.string.contains(pending.name))
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
        func footerTitleShowsAccountAndWorkspaceOnSeparateLines() {
            let title = MainSidebarAccountMenuButton.footerTitle(
                accountName: "Kazuki Matsuda",
                workspaceName: "Obsidian Workspace"
            )

            #expect(title.string.contains("Kazuki Matsuda"))
            #expect(title.string.contains("Obsidian Workspace"))
            #expect(title.string.contains("\n"))
            #expect(!title.string.contains("\u{FFFC}"))

            let accountRange = (title.string as NSString).range(of: "Kazuki Matsuda")
            let workspaceRange = (title.string as NSString).range(of: "Obsidian Workspace")
            let accountFont = title.attribute(.font, at: accountRange.location, effectiveRange: nil) as? NSFont
            let workspaceFont = title.attribute(.font, at: workspaceRange.location, effectiveRange: nil) as? NSFont
            let paragraphStyle = title.attribute(
                .paragraphStyle,
                at: accountRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            #expect(accountFont?.pointSize ?? 0 > workspaceFont?.pointSize ?? 0)
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
            let button = MainSidebarAccountButton(frame: .zero)
            let icon = try #require(button.subviews.compactMap { $0 as? NSImageView }.first)

            #expect(!icon.isAccessibilityElement())
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
                workspaces: [], currentWorkspace: nil, connections: connections,
                accountSelection: .init(connectionID: nil, isLocal: true, isLocalAvailable: true),
                onSelectWorkspace: { _ in }, onOpenSettings: { _ in }, onSelectAccount: { _ in }, onAccountAction: {}
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
        }

        @Test
        func keyboardAccountRowsSwitchAccountsAndPerformAccountAction() {
            let cloud = makeConnection(origin: "https://cloud.example.com", isCloud: true)
            let server = makeConnection(origin: "https://server.example.com", isCloud: false)
            var selectedConnectionID: UUID?
            var didSelectAccount = false
            var didManageAccounts = false
            let coordinator = MainSidebarAccountMenuCoordinator(
                workspaces: [],
                currentWorkspace: nil,
                connections: [cloud, server],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: cloud.id,
                    isLocal: false,
                    isLocalAvailable: true
                ),
                onSelectWorkspace: { _ in },
                onOpenSettings: { _ in },
                onSelectAccount: {
                    didSelectAccount = true
                    selectedConnectionID = $0?.id
                },
                onAccountAction: { didManageAccounts = true }
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
        func keyboardSelectionSkipsAccountsWithoutWorkspaces() {
            let unavailable = makeConnection(origin: "https://unused.example.com", isCloud: false, workspaceCount: 0)
            let available = makeConnection(origin: "https://used.example.com", isCloud: false)
            var selectedConnectionID: UUID?
            let coordinator = MainSidebarAccountMenuCoordinator(
                workspaces: [],
                currentWorkspace: nil,
                connections: [unavailable, available],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: nil,
                    isLocal: true,
                    isLocalAvailable: true
                ),
                onSelectWorkspace: { _ in },
                onOpenSettings: { _ in },
                onSelectAccount: { selectedConnectionID = $0?.id },
                onAccountAction: {}
            )

            coordinator.moveSelection(1)
            coordinator.activateSelection()

            #expect(selectedConnectionID == available.id)
        }

        @Test
        func currentWorkspaceRemainsSelectableButDoesNothing() {
            let current = makeWorkspace(name: "Current", accountConnectionID: nil)
            let other = makeWorkspace(name: "Other", accountConnectionID: nil)
            var selectedWorkspace: WorkspaceRecord?
            var openedCategory: SettingsCategory?
            let coordinator = MainSidebarAccountMenuCoordinator(
                workspaces: [current, other],
                currentWorkspace: current,
                connections: [],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: nil,
                    isLocal: true,
                    isLocalAvailable: true
                ),
                onSelectWorkspace: { selectedWorkspace = $0 },
                onOpenSettings: { openedCategory = $0 },
                onSelectAccount: { _ in },
                onAccountAction: {}
            )

            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(selectedWorkspace == nil)

            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(selectedWorkspace == other)

            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(openedCategory == .accountsAndWorkspaces)
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
