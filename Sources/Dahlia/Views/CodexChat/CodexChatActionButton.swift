import SwiftUI

struct CodexChatActionButton: View {
    let label: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: CodexChatDesign.controlSize, height: CodexChatDesign.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.primary.opacity(isEnabled ? 0.85 : 0.32), in: Circle())
        .disabled(!isEnabled)
        .help(label)
    }
}
