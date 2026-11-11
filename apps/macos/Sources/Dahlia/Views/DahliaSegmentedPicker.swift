import SwiftUI

struct DahliaSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).font(.dahliaBody).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .font(.dahliaBody)
    }
}
