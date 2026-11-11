import SwiftUI

/// `footer` keeps the main sidebar's account footer, and so the account menu, while Settings is open.
struct SettingsSidebarView<Footer: View>: View {
    @Binding var selection: SettingsCategory
    let onReturnToApp: () -> Void
    @ViewBuilder var footer: Footer
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            categoryList
            footer
        }
    }

    private var categoryList: some View {
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
                        .font(.dahliaSectionHeader)
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

extension SettingsSidebarView where Footer == EmptyView {
    init(selection: Binding<SettingsCategory>, onReturnToApp: @escaping () -> Void) {
        self.init(selection: selection, onReturnToApp: onReturnToApp) { EmptyView() }
    }
}
