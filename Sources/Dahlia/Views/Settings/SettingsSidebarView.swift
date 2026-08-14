import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    let onReturnToApp: () -> Void

    var body: some View {
        List(selection: $selection) {
            Button(action: onReturnToApp) {
                MainSidebarNavigationLabel(
                    title: L10n.backToApp,
                    systemImage: "arrow.left"
                )
            }
            .buttonStyle(.borderless)

            ForEach(SettingsGroup.allCases) { group in
                Section(group.label) {
                    ForEach(group.categories) { category in
                        MainSidebarNavigationLabel(
                            title: category.label,
                            systemImage: category.systemImage
                        )
                        .tag(category)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
