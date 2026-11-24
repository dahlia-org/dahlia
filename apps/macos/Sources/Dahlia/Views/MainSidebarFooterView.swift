import SwiftUI

/// The app has one account, so the footer holds app-wide actions: the settings menu, unprocessed recordings, updates, and help.
struct MainSidebarFooterView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    let workspaces: [WorkspaceRecord]
    let currentWorkspace: WorkspaceRecord?
    var updateController: AppUpdateController
    let unprocessedRecordingCount: Int
    let onShowUnprocessedRecordings: () -> Void

    @State private var isSettingsHovered = false
    @State private var isHelpHovered = false
    @State private var isMCPPresented = false

    var body: some View {
        HStack(spacing: 4) {
            MainSidebarAccountMenuButton(onOpenSettings: { mainWindowNavigation.openSettings(category: nil) })
                .footerMenuButtonStyle(isHovered: $isSettingsHovered, help: L10n.settings)

            if unprocessedRecordingCount > 0 {
                MainSidebarFooterIconButton(
                    title: L10n.unprocessedRecordings,
                    systemImage: "waveform.badge.exclamationmark",
                    count: unprocessedRecordingCount,
                    action: onShowUnprocessedRecordings
                )
            }

            Spacer(minLength: 0)

            if updateController.isUpdateAvailable {
                MainSidebarUpdateBadge(updateController: updateController)
            }

            MainSidebarHelpMenuButton(onOpenMCP: { isMCPPresented = true })
                .footerMenuButtonStyle(isHovered: $isHelpHovered, help: L10n.help)
        }
        .padding(.horizontal, 10)
        .frame(height: MainSidebarLayout.footerHeight)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
        }
        .sheet(isPresented: $isMCPPresented) {
            MCPModalView(
                workspaces: workspaces,
                currentWorkspace: currentWorkspace
            )
        }
    }
}

private extension View {
    /// The hover highlight and hit area of a footer button that opens an AppKit menu.
    func footerMenuButtonStyle(isHovered: Binding<Bool>, help: String) -> some View {
        frame(width: 30, height: 30)
            .background(
                isHovered.wrappedValue ? DahliaDesign.sidebarHighlightColor : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
            )
            .contentShape(.rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius))
            .help(help)
            .onHover { isHovered.wrappedValue = $0 }
    }
}

private struct MainSidebarFooterIconButton: View {
    let title: String
    let systemImage: String
    var count: Int?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                if let count {
                    Text(count.formatted())
                        .font(.dahliaSecondary)
                        .monospacedDigit()
                }
            }
            .font(.dahliaBody)
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, count == nil ? 0 : 6)
            .frame(minWidth: 30, minHeight: 30)
            .background(
                isHovered ? DahliaDesign.sidebarHighlightColor : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
            )
            .contentShape(.rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(count.map { $0.formatted() } ?? "")
    }
}
