import SwiftUI

struct DahliaInlineSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .dahliaFixedSymbol()
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand {
                    if text.isEmpty {
                        isFocused = false
                    } else {
                        text = ""
                    }
                }

            if !text.isEmpty {
                Button(L10n.clearSearch, systemImage: "xmark.circle.fill") {
                    text = ""
                    isFocused = true
                }
                .labelStyle(.iconOnly)
                .dahliaFixedSymbol()
                .buttonStyle(.plain)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .help(L10n.clearSearch)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: 280, minHeight: 24)
        .background(.background, in: .rect(cornerRadius: DahliaDesign.Field.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DahliaDesign.Field.cornerRadius)
                .stroke(.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
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
