import SwiftUI

struct MainSidebarNavigationLabel: View {
    let title: String
    let systemImage: String
    var badgeCount = 0
    var isSelected = false

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)

            Spacer(minLength: 8)

            if badgeCount > 0 {
                Text(badgeCount, format: .number)
                    .dahliaFont(.metadata)
                    .monospacedDigit()
                    .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .dahliaFont(.body)
        .foregroundStyle(DahliaDesign.sidebarPrimaryTextColor)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
    }
}
