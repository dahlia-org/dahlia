import AppKit
import SwiftUI

struct MainSidebarFooterView: View {
    static let verticalPadding: CGFloat = 8

    @MainActor private static let mcpIcon = Bundle.appModule.image(forResource: "MCPLogo")

    @Environment(\.openWindow) private var openWindow

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    let onSelectVault: (VaultRecord) -> Void

    @State private var isVaultHovered = false
    @State private var isMCPHovered = false
    @State private var isSettingsHovered = false
    @State private var isMCPPresented = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(vaults) { vault in
                    Button(action: { onSelectVault(vault) }, label: {
                        if vault.id == currentVault?.id {
                            Label(vault.name, systemImage: "checkmark")
                        } else {
                            Text(vault.name)
                        }
                    })
                    .disabled(vault.id == currentVault?.id)
                }

                Divider()

                Button(L10n.manageVaults, systemImage: "gearshape") {
                    openWindow(id: WindowID.vaultManager)
                }
            } label: {
                HStack(spacing: 6) {
                    Label(currentVault?.name ?? L10n.noVaultSelected, systemImage: "externaldrive")
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .background(
                    isVaultHovered ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onContinuousHover { phase in
                    isVaultHovered = phase != .ended
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(L10n.currentVaultDescription)
            .accessibilityLabel("\(L10n.currentVault), \(currentVault?.name ?? L10n.noVaultSelected)")

            Button(action: showMCP) {
                Label {
                    Text(L10n.mcp)
                } icon: {
                    if let mcpIcon = Self.mcpIcon {
                        Image(nsImage: mcpIcon)
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }
                }
                .labelStyle(.iconOnly)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
            }
            .background(isMCPHovered ? Color.primary.opacity(0.08) : .clear, in: Circle())
            .buttonStyle(.plain)
            .help(L10n.mcp)
            .onHover { isMCPHovered = $0 }
            .sheet(isPresented: $isMCPPresented) {
                MCPModalView(
                    vaults: vaults,
                    currentVault: currentVault
                )
            }

            SettingsLink {
                Label(L10n.settings, systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .padding(7)
                    .background(isSettingsHovered ? Color.primary.opacity(0.08) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.settingsMenuItem)
            .accessibilityLabel(L10n.settings)
            .onHover { isSettingsHovered = $0 }
        }
        .padding(2)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.verticalPadding)
    }

    private func showMCP() {
        isMCPPresented = true
    }
}
