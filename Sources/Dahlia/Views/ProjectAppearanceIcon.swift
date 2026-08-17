import SwiftUI

struct ProjectAppearanceIcon: View {
    let appearance: ProjectAppearance
    var isSelected = false

    var body: some View {
        Image(systemName: appearance.icon.rawValue)
            .foregroundStyle(isSelected ? Color.white : appearance.color.color)
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}
