import SwiftUI

struct ProjectAppearanceIcon: View {
    let appearance: ProjectAppearance

    var body: some View {
        Image(systemName: appearance.icon.systemImageName)
            .dahliaFixedSymbol()
            .foregroundStyle(appearance.color.color)
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}
