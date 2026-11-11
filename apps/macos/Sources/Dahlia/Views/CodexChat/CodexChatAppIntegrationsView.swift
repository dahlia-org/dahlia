import SwiftUI

struct CodexChatAppIntegrationsView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpenSettings) {
                HStack(spacing: 12) {
                    Text(L10n.chatAppIntegrations)
                        .fixedSize()
                    Spacer(minLength: 8)
                    ViewThatFits(in: .horizontal) {
                        appIcons(limit: 5)
                        appIcons(limit: 3)
                    }
                }
                .font(.dahliaBody)
                .foregroundStyle(isHovered ? DahliaDesign.primaryTextColor : DahliaDesign.secondaryTextColor)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                    isHovered ? DahliaDesign.sidebarHighlightColor : .clear,
                    in: .rect(cornerRadius: 10)
                )
                .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .dahliaHoverHelp(label: L10n.chatConfigureAppIntegrations)
            .accessibilityLabel(L10n.chatConfigureAppIntegrations)

            CodexChatIconButton(label: L10n.close, systemImage: "xmark", size: 24, action: onDismiss)
                .padding(.trailing, 6)
        }
        .background(DahliaDesign.contentHighlightColor, in: .rect(cornerRadius: 10))
    }

    private func appIcons(limit: Int) -> some View {
        let names = ["IntegrationSlack", "IntegrationGmail", "IntegrationGoogleDrive", "IntegrationGitHub", "IntegrationAtlassian"]
        return HStack(spacing: 8) {
            ForEach(names.prefix(limit), id: \.self) { name in
                if let icon = Bundle.appModule.image(forResource: name) {
                    Image(nsImage: icon)
                        .renderingMode(name == "IntegrationGitHub" ? .template : .original)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(DahliaDesign.primaryTextColor)
                        .frame(width: 16, height: 16)
                }
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}
