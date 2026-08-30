import SwiftUI

struct CodexChatApprovalMethodButton: View {
    @Bindable var session: CodexChatSessionModel

    @State private var isHovering = false
    @State private var isPresented = false
    @State private var windowBounds: CGRect = .zero

    var body: some View {
        Button(session.selectedApprovalMethod.title, systemImage: session.selectedApprovalMethod.systemImage, action: togglePanel)
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(session.selectedApprovalMethod == .fullAccess ? Color.orange : DahliaDesign.secondaryTextColor)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: CodexChatDesign.controlSize)
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
            session.refreshApprovalMethodAvailability()
            isPresented = true
        }
    }

    private func dismissPanel() {
        isPresented = false
    }
}
