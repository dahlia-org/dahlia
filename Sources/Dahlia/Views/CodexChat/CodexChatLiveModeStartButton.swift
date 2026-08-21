import SwiftUI

struct CodexChatLiveModeStartButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.enableChatLiveMode, systemImage: "waveform.badge.microphone")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [
                    CodexChatDesign.liveModeAccentLight,
                    CodexChatDesign.liveModeAccentDark,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: Circle()
        )
        .dahliaHoverHelp(label: L10n.chatLiveMode)
        .shadow(color: .purple.opacity(isEnabled ? 0.24 : 0), radius: 4, y: 1)
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
    }
}
