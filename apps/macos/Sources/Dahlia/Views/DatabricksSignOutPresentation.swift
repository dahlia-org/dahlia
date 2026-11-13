import SwiftUI

struct DatabricksSignOutPresentation: ViewModifier {
    @State private var settings = WorkspaceAISettingsModel.shared

    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(settings.pendingDatabricksSignOut != nil)
                .accessibilityHidden(settings.pendingDatabricksSignOut != nil)

            if let connection = settings.pendingDatabricksSignOut {
                ZStack {
                    Button(action: settings.cancelDatabricksSignOut) {
                        Color.black.opacity(0.16)
                            .ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 20) {
                        ProjectEditorSheetHeader(
                            title: L10n.signOutDahliaConnection(connection.accountLabel),
                            isDisabled: false,
                            onClose: settings.cancelDatabricksSignOut
                        )

                        Text(L10n.databricksSignOutDescription)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Spacer()

                            Button(L10n.cancel, role: .cancel, action: settings.cancelDatabricksSignOut)
                                .buttonStyle(.bordered)
                                .keyboardShortcut(.cancelAction)

                            Button(L10n.signOut, role: .destructive) {
                                Task { await settings.confirmDatabricksSignOut() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                        .controlSize(.extraLarge)
                    }
                    .font(.dahliaBody)
                    .padding(24)
                    .frame(width: 480)
                    .dahliaModalSurface()
                }
            }
        }
    }
}
