import SwiftUI

struct DahliaSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var isFocused: Bool
    @State private var keyboardOption: Value?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    Button {
                        guard selection != option else { return }
                        selection = option
                    } label: {
                        Text(label(option))
                            .font(.dahliaBody)
                    }
                    .buttonStyle(.dahlia(selection == option ? .primary : .secondary))
                    .focusable(false)
                    .overlay {
                        if isFocused, (keyboardOption ?? selection) == option {
                            RoundedRectangle(cornerRadius: DahliaDesign.Button.cornerRadius)
                                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                                .padding(-2)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .padding(3)
            .background(DahliaDesign.contentHighlightColor, in: .rect(cornerRadius: DahliaDesign.Button.cornerRadius + 3))
            .fixedSize(horizontal: true, vertical: false)
            .focusable(isEnabled && !options.isEmpty)
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .space], action: handleKeyPress)
            .onChange(of: isFocused) { _, focused in
                if !focused { keyboardOption = nil }
            }
            .onChange(of: selection) { _, value in
                keyboardOption = value
            }
            .accessibilityRepresentation {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(label(option)).font(.dahliaBody).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .font(.dahliaBody)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard isEnabled, let index = options.firstIndex(of: keyboardOption ?? selection) else { return .ignored }
        if press.key == .space {
            let option = options[index]
            if selection != option { selection = option }
        } else {
            let step = (press.key == .rightArrow) == (layoutDirection == .leftToRight) ? 1 : -1
            keyboardOption = options[(index + step + options.count) % options.count]
        }
        return .handled
    }
}
