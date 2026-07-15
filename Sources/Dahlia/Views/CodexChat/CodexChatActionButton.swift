import SwiftUI

struct CodexChatActionButton: View {
    let label: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(label, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
            .background(.primary.opacity(isEnabled ? 0.85 : 0.32), in: Circle())
            .contentShape(Circle())
            .disabled(!isEnabled)
            .help(label)
    }
}
