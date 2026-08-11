import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsGroup.allCases) { group in
                Section(group.label) {
                    ForEach(group.categories) { category in
                        Label(category.label, systemImage: category.systemImage)
                            .tag(category)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.settings)
    }
}
