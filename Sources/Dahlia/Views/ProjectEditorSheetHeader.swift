import SwiftUI

struct ProjectEditorSheetHeader: View {
    let title: String
    let isDisabled: Bool
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.title2)
                .bold()
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            Button(L10n.close, systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help(L10n.close)
        }
    }
}
