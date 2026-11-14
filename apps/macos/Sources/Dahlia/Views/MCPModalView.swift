import SwiftUI

struct MCPModalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var accountController = DahliaCloudAccountController.shared
    @State private var aiSettings = WorkspaceAISettingsModel.shared

    let workspaces: [WorkspaceRecord]
    let currentWorkspace: WorkspaceRecord?

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: L10n.mcp)

            MCPSettingsView(
                workspaces: workspaces,
                currentWorkspace: currentWorkspace,
                accountConnections: accountController.connections,
                databricksAccounts: aiSettings.databricksConnections
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DahliaSheetActionBar {
                Button(L10n.close, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .dahliaSimpleWindowStyle()
        .background {
            SheetOutsideClickMonitor(onOutsideClick: dismiss.callAsFunction)
        }
    }
}
