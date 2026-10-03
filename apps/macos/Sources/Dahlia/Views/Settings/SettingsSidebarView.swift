import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    let onReturnToApp: () -> Void
    @State private var searchText = ""

    var body: some View {
        List(selection: $selection) {
            Button(action: onReturnToApp) {
                MainSidebarNavigationLabel(
                    title: L10n.backToApp,
                    systemImage: "arrow.left"
                )
            }
            .buttonStyle(.borderless)

            DahliaInlineSearchField(placeholder: L10n.searchSettings, text: $searchText)
                .padding(.horizontal, -6)

            ForEach(SettingsGroup.allCases) { group in
                let categories = group.categories.filter { $0.matches(searchText) }
                if !categories.isEmpty {
                    Text(group.label)
                        .font(.body)
                        .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(.init(top: 8, leading: 16, bottom: 2, trailing: 16))
                        .accessibilityAddTraits(.isHeader)

                    ForEach(categories) { category in
                        MainSidebarNavigationLabel(
                            title: category.label,
                            systemImage: category.systemImage,
                            isSelected: selection == category
                        )
                        .tag(category)
                        .listRowInsets(.init(top: 1, leading: 16, bottom: 1, trailing: 16))
                    }
                }
            }
            if !SettingsGroup.allCases.flatMap(\.categories).contains(where: { $0.matches(searchText) }) {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}
