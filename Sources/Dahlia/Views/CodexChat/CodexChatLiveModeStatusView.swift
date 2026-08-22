import SwiftUI

struct CodexChatLiveModeStatusView: View {
    let isShortcutEnabled: Bool
    let onDisable: () -> Void
    let onSubmit: (String) -> Void

    @State private var isCloseHovered = false
    @State private var hoveredShortcut: String?

    private var shortcuts: [String] {
        [
            L10n.chatLiveModeSummarizeShortcut,
            L10n.chatLiveModeExplainShortcut,
            L10n.chatLiveModeHistoryShortcut,
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CodexChatDesign.liveModeStatusSpacing) {
            HStack(spacing: CodexChatDesign.liveModeStatusSpacing) {
                Label {
                    Text(L10n.chatLiveModeOn)
                        .foregroundStyle(DahliaDesign.primaryTextColor)
                } icon: {
                    Image(systemName: "waveform")
                        .foregroundStyle(CodexChatDesign.liveModeAccent)
                }
                .font(.body)

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
                .foregroundStyle(isCloseHovered ? DahliaDesign.primaryTextColor : DahliaDesign.secondaryTextColor)
                .background(isCloseHovered ? DahliaDesign.contentHighlightColor : .clear, in: Circle())
                .onHover { isCloseHovered = $0 }
                .help(L10n.disableChatLiveMode)
            }

            FlowLayout(spacing: 6, rowSpacing: 6) {
                shortcutButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, CodexChatDesign.liveModeStatusHorizontalPadding)
        .padding(.vertical, CodexChatDesign.liveModeStatusVerticalPadding)
        .background(
            DahliaDesign.contentHighlightColor,
            in: RoundedRectangle(cornerRadius: CodexChatDesign.liveModeStatusCornerRadius)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }

    private var shortcutButtons: some View {
        ForEach(shortcuts, id: \.self) { shortcut in
            Button(action: { onSubmit(shortcut) }) {
                Text(shortcut)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DahliaDesign.primaryTextColor)
            .dahliaChipSurface(tint: CodexChatDesign.liveModeAccent)
            .background(
                isShortcutEnabled && hoveredShortcut == shortcut
                    ? CodexChatDesign.liveModeAccent.opacity(0.06)
                    : .clear,
                in: Capsule()
            )
            .contentShape(Capsule())
            .disabled(!isShortcutEnabled)
            .opacity(isShortcutEnabled ? 1 : 0.6)
            .onHover { isHovered in
                hoveredShortcut = isShortcutEnabled && isHovered ? shortcut : nil
            }
            .accessibilityInputLabels([shortcut])
        }
    }
}
