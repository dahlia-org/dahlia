import SwiftUI

struct MainWindowNavigationToolbar: ToolbarContent {
    let isVisible: Bool
    let isSidebarVisible: Bool
    let isChatSidebarVisible: Bool
    let chatSidebarWidth: CGFloat
    let chatSessionTitle: String
    let isShowingChatHistory: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let onToggleSidebar: () -> Void
    let onSearch: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onNewChat: () -> Void
    let onShowChatHistory: () -> Void
    let onHideChatHistory: () -> Void
    let onPopOutChat: () -> Void
    let onToggleChat: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            HStack(spacing: 6) {
                Button(sidebarToggleLabel, systemImage: "sidebar.left", action: onToggleSidebar)
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .help(sidebarToggleLabel)
                    .accessibilityLabel(sidebarToggleLabel)
                Button(L10n.search, systemImage: "magnifyingglass", action: onSearch)
                    .keyboardShortcut("k", modifiers: .command)
                    .help(L10n.searchMeetingsAndProjects)
                    .accessibilityLabel(L10n.search)
                Button(L10n.back, systemImage: "arrow.backward", action: onGoBack)
                    .disabled(!canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help(L10n.back)
                    .accessibilityLabel(L10n.back)
                Button(L10n.forward, systemImage: "arrow.forward", action: onGoForward)
                    .disabled(!canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help(L10n.forward)
                    .accessibilityLabel(L10n.forward)
            }
            .labelStyle(.iconOnly)
            .controlSize(.regular)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .disabled(!isVisible)
            .accessibilityHidden(!isVisible)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible)

        ToolbarItem {
            HStack(spacing: 12) {
                if isChatSidebarVisible {
                    HStack(spacing: 6) {
                        if isShowingChatHistory {
                            Button(L10n.back, systemImage: "chevron.left", action: onHideChatHistory)
                                .help(L10n.back)
                                .accessibilityLabel(L10n.back)
                            Text(L10n.chatHistory)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Button(L10n.newChat, systemImage: "square.and.pencil", action: onNewChat)
                                .help(L10n.newChat)
                                .accessibilityLabel(L10n.newChat)
                            Text(chatSessionTitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    HStack(spacing: 6) {
                        if !isShowingChatHistory {
                            Button(L10n.chatHistory, systemImage: "clock.arrow.circlepath", action: onShowChatHistory)
                                .help(L10n.chatHistory)
                                .accessibilityLabel(L10n.chatHistory)
                        }
                        Button(L10n.popOutChat, systemImage: "rectangle.on.rectangle", action: onPopOutChat)
                            .help(L10n.popOutChat)
                            .accessibilityLabel(L10n.popOutChat)
                    }
                }

                Button(chatSidebarToggleLabel, systemImage: "sidebar.right", action: onToggleChat)
                    .help(chatSidebarToggleLabel)
                    .accessibilityLabel(chatSidebarToggleLabel)
                    .accessibilityValue(isChatSidebarVisible ? L10n.shown : L10n.hidden)
            }
            .frame(
                width: isChatSidebarVisible ? MainChatSidebarLayout.toolbarContentWidth(for: chatSidebarWidth) : nil,
                alignment: .trailing
            )
            .labelStyle(.iconOnly)
            .controlSize(.regular)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .disabled(!isVisible)
            .accessibilityHidden(!isVisible)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var sidebarToggleLabel: String {
        isSidebarVisible ? L10n.hideSidebar : L10n.showSidebar
    }

    private var chatSidebarToggleLabel: String {
        isChatSidebarVisible ? L10n.hideChat : L10n.showChat
    }
}
