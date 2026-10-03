import SwiftUI

extension View {
    func mainDetailPane() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
            .layoutPriority(1)
    }
}
