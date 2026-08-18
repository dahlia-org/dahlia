import SwiftUI

struct DahliaSheetHeader: View {
    let title: String

    var body: some View {
        DahliaWindowHeader(allowsWindowDragging: false) {
            Text(title)
                .dahliaFont(.subsectionTitle, weight: .semibold)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)
        }
    }
}
