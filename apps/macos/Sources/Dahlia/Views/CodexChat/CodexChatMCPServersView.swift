import SwiftUI

struct CodexChatMCPServersView: View {
    let settings: AgentMCPSettings
    let onBack: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodexChatConfigurationRow(
                title: L10n.chatMCPServers,
                isSelected: false,
                leadingSystemImage: "chevron.left",
                action: onBack
            )
            .accessibilityLabel("\(L10n.back), \(L10n.chatMCPServers)")

            if settings.servers.isEmpty {
                Text(L10n.chatNoMCPServers)
                    .font(.dahliaBody)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(settings.servers) { server in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.dahliaBody)
                                    .foregroundStyle(DahliaDesign.primaryTextColor)
                                Text(server.service)
                                    .font(.dahliaSecondary)
                                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                            }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 10)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(idealHeight: min(CGFloat(settings.servers.count) * 44, 220), maxHeight: 220)
                .scrollBounceBehavior(.basedOnSize)
            }

            CodexChatConfigurationRow(
                title: L10n.mcpSettings,
                isSelected: false,
                leadingSystemImage: "gearshape",
                action: onOpenSettings
            )
        }
        .padding(10)
    }
}
