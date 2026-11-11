import SwiftUI

struct CodexChatApprovalMethodButton: View {
    @Bindable var session: CodexChatSessionModel

    @State private var isHovering = false
    @State private var isPresented = false
    @State private var windowBounds: CGRect = .zero

    var body: some View {
        Button(action: togglePanel) {
            Label(session.selectedApprovalMethod.title, systemImage: session.selectedApprovalMethod.systemImage)
                .padding(.horizontal, 10)
                .frame(height: CodexChatDesign.controlSize)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .font(.dahliaBody)
        .foregroundStyle(DahliaDesign.secondaryTextColor)
        .lineLimit(1)
        .background(
            isHovering || isPresented ? DahliaDesign.contentHighlightColor : .clear,
            in: Capsule()
        )
        .onHover { isHovering = $0 }
        .dahliaHoverHelp(label: L10n.chatChangePermissions)
        .overlay(alignment: .bottomLeading) {
            if isPresented {
                CodexChatApprovalMethodPanel(
                    session: session,
                    width: panelWidth,
                    onDismiss: dismissPanel
                )
                .codexChatDismissOnOutsideClick(perform: dismissPanel)
                .offset(
                    x: CodexChatApprovalMethodPanelLayout.horizontalOffset(
                        windowBounds: windowBounds,
                        panelWidth: panelWidth
                    ),
                    y: -(CodexChatDesign.controlSize + CodexChatDesign.floatingPanelSpacing)
                )
                .zIndex(1)
            }
        }
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.bounds(of: .named(DahliaWindowHeaderHelpLayout.windowCoordinateSpaceName))
                ?? .zero
        } action: { bounds in
            windowBounds = bounds
        }
        .onExitCommand(perform: dismissPanel)
        .zIndex(isPresented ? 1 : 0)
    }

    private var panelWidth: CGFloat {
        CodexChatApprovalMethodPanelLayout.width(windowBounds: windowBounds)
    }

    private func togglePanel() {
        if isPresented {
            dismissPanel()
        } else {
            isPresented = true
        }
    }

    private func dismissPanel() {
        isPresented = false
    }
}
