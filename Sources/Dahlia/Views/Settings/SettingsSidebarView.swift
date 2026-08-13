import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    let onReturnToApp: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onReturnToApp) {
                MainSidebarNavigationLabel(
                    title: L10n.backToApp,
                    systemImage: "arrow.left"
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            List(selection: $selection) {
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
        .navigationTitle(L10n.settings)
    }
}
