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
        func syncProgressFitsTheMenuAndAppearsInTheFooter() throws {
            let pending = VaultSyncProgress(
                id: UUID(),
                name: "Work Vault",
                state: .pending,
                phase: .attachments,
                meetings: 0,
                files: 2400,
                attachments: 2400,
                other: 0
            )
            let progress = AccountSyncProgress(vaults: [pending])
            let footer = MainSidebarAccountMenuButton.footerTitle(accountName: "Account", vaultName: pending.name, syncSummary: progress.summary)
            #expect(footer.string.contains(progress.summary))
            #expect(footer.string.contains(pending.name))
            let menu = NSHostingView(rootView: MainSidebarAccountMenuPanel(width: 320) {
                SyncProgressView(connections: [])
            }.fixedSize())
            #expect(menu.fittingSize.width == 320)
            #expect(menu.fittingSize.height > 40 && menu.fittingSize.height <= 432)

            let rows = [
                VaultSyncProgress(
                    id: UUID(),
                    name: "Preparing",
                    state: .pending,
                    phase: .preparing,
                    meetings: 0,
                    files: 0,
                    attachments: 0,
                    other: 0
                ),
                pending,
                VaultSyncProgress(
                    id: UUID(),
                    name: "Needs attention",
                    state: .blocked(.authorization),
                    phase: .attention,
                    meetings: 2,
                    files: 8,
                    attachments: 8,
                    other: 0
                ),
            ]
            let preview = MainSidebarAccountMenuPanel(width: 320) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.syncProgress).font(.headline)
                    ForEach(rows) { VaultSyncProgressView(progress: $0) }
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
        func footerTitleShowsAccountAndVaultOnSeparateLines() {
            let title = MainSidebarAccountMenuButton.footerTitle(
                accountName: "Kazuki Matsuda",
                vaultName: "Obsidian Vault"
            )

            #expect(title.string.contains("Kazuki Matsuda"))
            #expect(title.string.contains("Obsidian Vault"))
            #expect(title.string.contains("\n"))
            #expect(!title.string.contains("\u{FFFC}"))

            let accountRange = (title.string as NSString).range(of: "Kazuki Matsuda")
            let vaultRange = (title.string as NSString).range(of: "Obsidian Vault")
            let accountFont = title.attribute(.font, at: accountRange.location, effectiveRange: nil) as? NSFont
            let vaultFont = title.attribute(.font, at: vaultRange.location, effectiveRange: nil) as? NSFont
            let paragraphStyle = title.attribute(
                .paragraphStyle,
                at: accountRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            #expect(accountFont?.pointSize ?? 0 > vaultFont?.pointSize ?? 0)
            #expect(paragraphStyle?.firstLineHeadIndent == 6)
            #expect(paragraphStyle?.headIndent == 6)
        }

        @Test
        func accountVaultsUseCreationOrderAndExcludeOtherAccounts() {
            let connectionID = UUID.v7()
            let first = makeVault(name: "First", accountConnectionID: connectionID, createdAt: .distantPast)
            let local = makeVault(name: "Local", accountConnectionID: nil)
            let second = makeVault(name: "Second", accountConnectionID: connectionID, createdAt: .now)

            #expect(MainSidebarFooterView.vaults([second, local, first], linkedTo: connectionID) == [first, second])
            #expect(MainSidebarFooterView.vaults([first, local, second], linkedTo: nil) == [local])
            #expect(MainSidebarFooterView.vaultToSelect(
                from: [first, local, second],
                currentVault: local,
                connectionID: connectionID
            ) == first)
            #expect(MainSidebarFooterView.vaultToSelect(
                from: [first, local, second],
                currentVault: first,
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
        func accountHelpCentersAboveTheRowAndStaysOnScreen() {
            let origin = MainSidebarAccountMenuLayout.helpOrigin(
                panelSize: CGSize(width: 240, height: 36),
                rowFrame: CGRect(x: 6, y: 36, width: 268, height: 30),
                mainPanelFrame: CGRect(x: 700, y: 200, width: 280, height: 180),
                screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            )

            #expect(origin == CGPoint(x: 720, y: 350))
        }

        @Test
        func accountHelpFallsBelowTheRowWhenSpaceAboveIsInsufficient() {
            let origin = MainSidebarAccountMenuLayout.helpOrigin(
                panelSize: CGSize(width: 240, height: 36),
                rowFrame: CGRect(x: 6, y: 36, width: 268, height: 30),
                mainPanelFrame: CGRect(x: 700, y: 614, width: 280, height: 180),
                screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            )

            #expect(origin == CGPoint(x: 720, y: 686))
            #expect(origin.y + 36 < 794 - 66)
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

        @Test(.timeLimit(.minutes(1)), arguments: [UInt16(125), 121, 49, 119])
        func syncProgressConsumesKeysAndScrollsItsOwnPanel(keyCode: UInt16) async throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
            window.contentView?.addSubview(button)
            let connections = (0 ..< 20).map { makeConnection(origin: "https://server-\($0).example.com", isCloud: false) }
            let coordinator = MainSidebarAccountMenuCoordinator(
                vaults: [], currentVault: nil, connections: connections,
                accountSelection: .init(connectionID: nil, isLocal: true, isLocalAvailable: true),
                onSelectVault: { _ in }, onOpenSettings: { _ in }, onSelectAccount: { _ in }, onAccountAction: {}
            )
            coordinator.button = button
            defer { coordinator.dismissMenu()
                window.close()
            }
            coordinator.toggleMenu()
            for _ in 0 ... coordinator.syncProgressIndex {
                coordinator.moveSelection(1)
            }
            coordinator.openSelectedSubmenu()
            let panel = try #require(window.childWindows?.last)
            let content = try #require(panel.contentView)
            content.layoutSubtreeIfNeeded()
            func findScrollView(_ view: NSView) -> NSScrollView? {
                (view as? NSScrollView) ?? view.subviews.lazy.compactMap { findScrollView($0) }.first
            }
            let scroll = try #require(findScrollView(content))
            #expect(!panel.canBecomeKey)
            #expect(try #require(scroll.documentView).frame.height > scroll.contentView.bounds.height)
            let initial = scroll.contentView.bounds.origin.y
            let down = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: keyCode
            ))
            #expect(coordinator.handleKeyDown(down) == nil)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while scroll.contentView.bounds.origin.y == initial, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(scroll.contentView.bounds.origin.y > initial)
        }

        @Test
        func keyboardAccountRowsSwitchAccountsAndPerformAccountAction() {
            let cloud = makeConnection(origin: "https://cloud.example.com", isCloud: true)
            let server = makeConnection(origin: "https://server.example.com", isCloud: false)
            var selectedConnectionID: UUID?
            var didSelectAccount = false
            var didManageAccounts = false
            let coordinator = MainSidebarAccountMenuCoordinator(
                vaults: [],
                currentVault: nil,
                connections: [cloud, server],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: cloud.id,
                    isLocal: false,
                    isLocalAvailable: true
                ),
                onSelectVault: { _ in },
                onOpenSettings: { _ in },
                onSelectAccount: {
                    didSelectAccount = true
                    selectedConnectionID = $0?.id
                },
                onAccountAction: { didManageAccounts = true }
            )

            var openedURLs: [URL] = []
            coordinator.openURL = { openedURLs.append($0) }
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(selectedConnectionID == server.id)
            #expect(openedURLs.isEmpty)

            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(didSelectAccount)
            #expect(selectedConnectionID == nil)
            #expect(openedURLs.isEmpty)

            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(openedURLs.map(\.absoluteString) == [cloud.origin])
            #expect(selectedConnectionID == nil)

            coordinator.moveSelection(-1)
            coordinator.activateSelection()
            #expect(didManageAccounts)
        }

        @Test
        func keyboardSelectionSkipsAccountsWithoutVaults() {
            let unavailable = makeConnection(origin: "https://unused.example.com", isCloud: false, vaultCount: 0)
            let available = makeConnection(origin: "https://used.example.com", isCloud: false)
            var selectedConnectionID: UUID?
            let coordinator = MainSidebarAccountMenuCoordinator(
                vaults: [],
                currentVault: nil,
                connections: [unavailable, available],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: nil,
                    isLocal: true,
                    isLocalAvailable: true
                ),
                onSelectVault: { _ in },
                onOpenSettings: { _ in },
                onSelectAccount: { selectedConnectionID = $0?.id },
                onAccountAction: {}
            )

            coordinator.openURL = { _ in }
            coordinator.moveSelection(1)
            coordinator.activateSelection()

            #expect(selectedConnectionID == available.id)
        }

        @Test
        func currentVaultRemainsSelectableButDoesNothing() {
            let current = makeVault(name: "Current", accountConnectionID: nil)
            let other = makeVault(name: "Other", accountConnectionID: nil)
            var selectedVault: VaultRecord?
            var openedCategory: SettingsCategory?
            let coordinator = MainSidebarAccountMenuCoordinator(
                vaults: [current, other],
                currentVault: current,
                connections: [],
                accountSelection: MainSidebarAccountSelection(
                    connectionID: nil,
                    isLocal: true,
                    isLocalAvailable: true
                ),
                onSelectVault: { selectedVault = $0 },
                onOpenSettings: { openedCategory = $0 },
                onSelectAccount: { _ in },
                onAccountAction: {}
            )

            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(selectedVault == nil)

            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(selectedVault == other)

            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.moveSelection(1)
            coordinator.activateSelection()
            #expect(openedCategory == .accountsAndVaults)
        }

        private func makeConnection(origin: String, isCloud: Bool, vaultCount: Int = 1) -> DahliaAccountConnection {
            DahliaAccountConnection(
                record: DahliaAccountConnectionRecord(
                    id: .v7(),
                    origin: origin,
                    clientID: "desktop-client",
                    createdAt: .now
                ),
                account: DahliaCloudAccount(id: origin, name: origin, email: nil),
                isCloud: isCloud,
                vaultCount: vaultCount
            )
        }

        private func makeVault(
            name: String,
            accountConnectionID: UUID?,
            createdAt: Date = .now
        ) -> VaultRecord {
            VaultRecord(
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
