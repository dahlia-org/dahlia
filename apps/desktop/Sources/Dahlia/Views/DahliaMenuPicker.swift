import SwiftUI

struct DahliaMenuPicker<Value: Hashable>: View {
    let title: String
    var description: String?
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        Picker(selection: $selection) {
            if !options.contains(selection) {
                Text(label(selection)).tag(selection).disabled(true)
            }
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        } label: {
            Text(title)
            if let description {
                Text(description)
            }
        }
        .pickerStyle(.menu)
    }
}
