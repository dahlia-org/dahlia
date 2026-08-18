import SwiftUI

struct ProjectEditorSheetHeader: View {
    let title: String
    let isDisabled: Bool
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .dahliaFont(.displayTitle)
                .bold()
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            Button(L10n.close, systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .dahliaFixedSymbol()
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help(L10n.close)
        }
    }
}
