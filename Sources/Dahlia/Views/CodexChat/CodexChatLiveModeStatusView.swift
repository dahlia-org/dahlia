import SwiftUI

struct CodexChatLiveModeStatusView: View {
    let onDisable: () -> Void

    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: CodexChatDesign.liveModeStatusSpacing) {
            Label(L10n.chatLiveModeOn, systemImage: "waveform")
                .dahliaFont(.body)
                .foregroundStyle(Color.accentColor)

            Spacer(minLength: CodexChatDesign.liveModeStatusSpacing)

            Button(action: onDisable) {
                Label(L10n.disableChatLiveMode, systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(
                        width: CodexChatDesign.liveModeCloseButtonSize,
                        height: CodexChatDesign.liveModeCloseButtonSize
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isCloseHovered ? .primary : .secondary)
            .background(isCloseHovered ? DahliaDesign.hoverHighlightColor : .clear, in: Circle())
            .onHover { isCloseHovered = $0 }
            .help(L10n.disableChatLiveMode)
        }
        .padding(.horizontal, CodexChatDesign.liveModeStatusHorizontalPadding)
        .padding(.vertical, CodexChatDesign.liveModeStatusVerticalPadding)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: CodexChatDesign.liveModeStatusCornerRadius))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}
