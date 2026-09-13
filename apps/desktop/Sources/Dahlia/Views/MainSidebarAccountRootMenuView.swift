import SwiftUI

struct MainSidebarAccountRootMenuView: View {
    var navigation: MainSidebarAccountMenuNavigationState

    let connections: [DahliaAccountConnection]
    let currentConnectionID: UUID?
    let isLocalAccount: Bool
    let isLocalAccountAvailable: Bool
    let workspaces: [WorkspaceRecord]
    let currentWorkspace: WorkspaceRecord?
    let onShowLanguages: (CGFloat?) -> Void
    let onShowSyncProgress: (CGFloat?) -> Void
    let onDismissSubmenu: () -> Void
    let onShowAccountHelp: (String, CGRect) -> Void
    let onDismissAccountHelp: () -> Void
    let onOpenSettings: (SettingsCategory?) -> Void
    let onSelectAccount: (DahliaAccountConnection?) -> Void
    let onSelectWorkspace: (WorkspaceRecord) -> Void
    let onManageWorkspaces: () -> Void
    let onAccountAction: () -> Void

    @State private var accountController = DahliaCloudAccountController.shared
    @State private var pendingHoverTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 2) {
            if let currentAccount = currentConnection?.account {
                Text(currentAccount.email ?? currentAccount.displayName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

            }

            ForEach(connections.enumerated(), id: \.element.id) { index, connection in
                MainSidebarAccountMenuRow(
                    title: connection.displayName,
                    subtitle: accountController.syncProgress[connection.id]?.summary
                        ?? (connection.isCloud ? L10n.dahliaCloud : L10n.dahliaServer),
                    syncState: accountController.syncStates[connection.id] ?? .pending,
                    selectionState: connection.id == currentConnectionID,
                    isEnabled: connection.workspaceCount > 0,
                    isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == index,
                    help: connection.origin,
                    showsHelp: false,
                    onHoverStart: { hover(index: index, submenu: nil, action: onDismissSubmenu) },
                    onHoverStartInFrame: { frame in
                        onShowAccountHelp(connection.origin, frame)
                    },
                    onHoverEnd: {
                        cancelPendingHover()
                        onDismissAccountHelp()
                    },
                    action: { activate(index: index, action: { onSelectAccount(connection) }) }
                )
            }

            MainSidebarAccountMenuRow(
                title: L10n.localAccount,
                image: Image(systemName: "person.2"),
                selectionState: isLocalAccount,
                isEnabled: isLocalAccountAvailable,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == connections.count,
                onHoverStart: { hover(index: connections.count, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: connections.count, action: { onSelectAccount(nil) }) }
            )

            Divider()
                .padding(.vertical, 4)

            Text(L10n.workspace)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .accessibilityAddTraits(.isHeader)

            ForEach(workspaces.enumerated(), id: \.element.id) { index, workspace in
                MainSidebarAccountMenuRow(
                    title: workspace.name,
                    image: Image(systemName: (workspace.appearance ?? .workspaceDefault).icon.systemImageName),
                    imageColor: (workspace.appearance ?? .workspaceDefault).color.color,
                    selectionState: workspace.id == currentWorkspace?.id,
                    isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == workspaceOffset + index,
                    onHoverStart: { hover(index: workspaceOffset + index, submenu: nil, action: onDismissSubmenu) },
                    onHoverEnd: cancelPendingHover,
                    action: { activate(index: workspaceOffset + index, action: { onSelectWorkspace(workspace) }) }
                )
            }

            MainSidebarAccountMenuRow(
                title: L10n.manageWorkspaces,
                image: Image(systemName: "gearshape"),
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == manageWorkspacesIndex,
                onHoverStart: { hover(index: manageWorkspacesIndex, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: manageWorkspacesIndex, action: onManageWorkspaces) }
            )

            if !connections.isEmpty {
                MainSidebarAccountMenuRow(
                    title: L10n.syncProgress,
                    image: Image(systemName: "arrow.triangle.2.circlepath"),
                    showsDisclosure: true,
                    isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == syncProgressIndex,
                    onHoverStartAtY: { minY in
                        hover(index: syncProgressIndex, submenu: .syncProgress, action: { onShowSyncProgress(minY) })
                    },
                    onHoverEnd: cancelPendingHover,
                    action: { activate(index: syncProgressIndex, action: { onShowSyncProgress(nil) }) }
                )
            }

            Divider()
                .padding(.vertical, 4)

            MainSidebarAccountMenuRow(
                title: L10n.language,
                image: Image(systemName: "globe"),
                showsDisclosure: true,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset,
                onHoverStartAtY: { minY in hover(index: menuOffset, submenu: .languages, action: { onShowLanguages(minY) }) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset, action: { onShowLanguages(nil) }) }
            )

            MainSidebarAccountMenuRow(
                title: L10n.settings,
                image: Image(systemName: "gearshape"),
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset + 1,
                onHoverStart: { hover(index: menuOffset + 1, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset + 1, action: { onOpenSettings(nil) }) }
            )

            Divider()
                .padding(.vertical, 4)

            MainSidebarAccountMenuRow(
                title: currentConnection == nil ? L10n.dahliaSignIn : L10n.signOut,
                image: Image(systemName: currentConnection == nil ? "person" : "rectangle.portrait.and.arrow.right"),
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset + 2,
                onHoverStart: { hover(index: menuOffset + 2, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset + 2, action: onAccountAction) }
            )
        }
        .onDisappear(perform: cancelPendingHover)
    }

    private var workspaceOffset: Int { connections.count + 1 }
    private var manageWorkspacesIndex: Int { workspaceOffset + workspaces.count }
    private var syncProgressIndex: Int { manageWorkspacesIndex + 1 }
    private var menuOffset: Int { syncProgressIndex + (connections.isEmpty ? 0 : 1) }
    private var currentConnection: DahliaAccountConnection? {
        connections.first { $0.id == currentConnectionID }
    }

    private func hover(
        index: Int,
        submenu: MainSidebarAccountMenuNavigationState.ActiveMenu?,
        action: @escaping () -> Void
    ) {
        cancelPendingHover()
        guard let submenu else {
            action()
            navigation.selectRoot(index)
            return
        }
        guard navigation.activeMenu != submenu else { return }
        let applyHover = {
            navigation.selectRoot(index)
            action()
        }
        guard navigation.activeMenu != .root else {
            applyHover()
            return
        }
        pendingHoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            pendingHoverTask = nil
            applyHover()
        }
    }

    private func activate(index: Int, action: () -> Void) {
        cancelPendingHover()
        navigation.selectRoot(index)
        action()
    }

    private func cancelPendingHover() {
        pendingHoverTask?.cancel()
        pendingHoverTask = nil
    }
}
