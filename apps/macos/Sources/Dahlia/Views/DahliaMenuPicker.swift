import SwiftUI

struct DahliaMenuPicker<Value: Hashable>: View {
    let title: String
    var description: String?
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        // Native pickers need a font on each option to style the selected title; the inherited font alone is ignored.
        Picker(selection: $selection) {
            if !options.contains(selection) {
                Text(label(selection)).font(.dahliaBody).tag(selection).disabled(true)
            }
            ForEach(options, id: \.self) { option in
                Text(label(option)).font(.dahliaBody).tag(option)
            }
        } label: {
            Text(title)
            if let description {
                Text(description)
            }
        }
        .pickerStyle(.menu)
        .font(.dahliaBody)
    }
}
