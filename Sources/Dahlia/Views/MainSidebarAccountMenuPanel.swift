import SwiftUI

struct MainSidebarAccountMenuPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(6)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}
