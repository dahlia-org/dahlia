import SwiftUI

struct DahliaMenuPicker<Value: Hashable>: View {
    let title: String
    var description: String?
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        LabeledContent {
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                Label(label(selection), systemImage: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.dahlia())
            .accessibilityLabel(title)
            .accessibilityValue(label(selection))
        } label: {
            Text(title)
            if let description {
                Text(description)
            }
        }
    }
}
