import SwiftUI

struct DahliaSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { option in
                    Button(label(option)) {
                        selection = option
                    }
                    .buttonStyle(.dahlia(option == selection ? .primary : .secondary))
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
                }
            }
            .accessibilityRepresentation {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(label(option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}
