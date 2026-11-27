import SwiftUI

struct DahliaSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

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
                }
            }
            .padding(3)
            .background(DahliaDesign.contentHighlightColor, in: .rect(cornerRadius: DahliaDesign.Button.cornerRadius + 3))
            .fixedSize(horizontal: true, vertical: false)
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
}
