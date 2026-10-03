import SwiftUI

struct DahliaInlineSearchField: View {
    let placeholder: String
    @Binding var text: String
    @State private var isFocused = false

    var body: some View {
        NonAutofocusingSearchField(
            text: $text,
            isFocused: $isFocused,
            placeholder: placeholder
        )
        .frame(maxWidth: .infinity, minHeight: 28)
        .background {
            Button(action: { isFocused = true }) {
                Label(placeholder, systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
