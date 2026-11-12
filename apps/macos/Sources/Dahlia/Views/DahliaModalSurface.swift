import SwiftUI

extension View {
    @ViewBuilder
    func dahliaModalSurface(isEmbedded: Bool = false) -> some View {
        if isEmbedded {
            self
        } else {
            background(Color(nsColor: .windowBackgroundColor))
                .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                        .strokeBorder(.primary.opacity(0.2), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
    }
}
