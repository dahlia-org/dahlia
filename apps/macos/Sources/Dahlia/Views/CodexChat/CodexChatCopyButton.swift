import SwiftUI

struct CodexChatCopyButton: View {
    let text: String
    var title = L10n.copyChatMessage
    var isVisible = true
    var feedbackAlignment: Alignment = .topTrailing

    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var isCopied = false

    var body: some View {
        Button(action: copyMessage) {
            Label(isCopied ? L10n.copied : title, systemImage: isCopied ? "checkmark" : "square.on.square")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(isHovered ? DahliaDesign.contentHighlightColor : .clear, in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .font(.dahliaSecondary)
        .foregroundStyle(isCopied ? Color.accentColor : DahliaDesign.optionalTextColor)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help(isCopied ? L10n.copied : title)
        .overlay(alignment: feedbackAlignment) {
            if isCopied {
                DahliaWindowHeaderHelp(label: L10n.copied, shortcut: nil)
                    .alignmentGuide(.top) { $0[.bottom] + 6 }
            }
        }
        .opacity(isVisible || isFocused || isVoiceOverEnabled ? 1 : 0)
        .allowsHitTesting(isVisible || isFocused || isVoiceOverEnabled)
        .task(id: isCopied) {
            guard isCopied else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            isCopied = false
        }
        .onChange(of: text) { isCopied = false }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        isCopied = NSPasteboard.general.setString(text, forType: .string)
    }
}
