import SwiftUI

struct MainSidebarNavigationLabel: View {
    let title: String
    let systemImage: String
    var isSelected = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
    }
}
