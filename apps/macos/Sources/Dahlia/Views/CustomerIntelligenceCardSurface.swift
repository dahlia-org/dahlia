import SwiftUI

extension View {
    func customerIntelligenceCardSurface() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}
