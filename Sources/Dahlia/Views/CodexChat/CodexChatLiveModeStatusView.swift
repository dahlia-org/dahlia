import SwiftUI

struct CodexChatLiveModeStatusView: View {
    @Binding var isEnabled: Bool
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: CodexChatDesign.liveModeStatusSpacing) {
            Label(statusText, systemImage: "waveform")
                .font(.subheadline)
                .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                .accessibilityHidden(true)

            Spacer(minLength: CodexChatDesign.liveModeStatusSpacing)

            Toggle(L10n.chatLiveMode, isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isAvailable)
                .accessibilityLabel(L10n.chatLiveMode)
                .accessibilityValue(statusText)
                .help(isEnabled ? L10n.disableChatLiveMode : L10n.enableChatLiveMode)
        }
        .padding(.horizontal, CodexChatDesign.liveModeStatusHorizontalPadding)
        .padding(.vertical, CodexChatDesign.liveModeStatusVerticalPadding)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: CodexChatDesign.liveModeStatusCornerRadius))
    }

    private var statusText: String {
        isEnabled ? L10n.chatLiveModeOn : L10n.chatLiveModeOff
    }
}
