import SwiftUI

struct MCPModalView: View {
    @Environment(\.dismiss) private var dismiss

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?

    var body: some View {
        NavigationStack {
            MCPSettingsView(
                vaults: vaults,
                currentVault: currentVault
            )
            .navigationTitle(L10n.mcp)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.close, action: dismiss.callAsFunction)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .background {
            SheetOutsideClickMonitor(onOutsideClick: dismiss.callAsFunction)
        }
    }
}
