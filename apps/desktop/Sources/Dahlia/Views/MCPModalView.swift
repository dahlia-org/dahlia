import SwiftUI

struct MCPModalView: View {
    @Environment(\.dismiss) private var dismiss

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: L10n.mcp)

            MCPSettingsView(
                vaults: vaults,
                currentVault: currentVault
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
