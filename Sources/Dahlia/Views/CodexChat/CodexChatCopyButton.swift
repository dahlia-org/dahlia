import SwiftUI

struct CodexChatCopyButton: View {
    let text: String
    var title = L10n.copyChatMessage

    @State private var copyCount = 0

    var body: some View {
        Button(action: copyMessage) {
            Label(title, systemImage: "square.on.square")
                .labelStyle(.iconOnly)
                .symbolEffect(.bounce, options: .speed(1.5), value: copyCount)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(DahliaDesign.optionalTextColor)
        .help(title)
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyCount += 1
    }
}
