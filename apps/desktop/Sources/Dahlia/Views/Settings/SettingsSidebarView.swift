import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    var updateController: AppUpdateController
    let onSelectVault: (VaultRecord) -> Void
    let onReturnToApp: () -> Void
    @State private var searchText = ""
    @State private var expandedGroups = Set(SettingsGroup.allCases.filter { $0 != .advanced })

    var body: some View {
        VStack(spacing: 0) {
            DahliaInlineSearchField(placeholder: L10n.searchSettings, text: $searchText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            List(selection: $selection) {
                Button(action: onReturnToApp) {
                    MainSidebarNavigationLabel(
                        title: L10n.backToApp,
                        systemImage: "arrow.left"
                    )
                }
                .buttonStyle(.borderless)

                ForEach(SettingsGroup.allCases) { group in
                    let categories = group.categories.filter { $0.matches(searchText) }
                    if !categories.isEmpty {
                        Section(isExpanded: Binding(
                            get: { expandedGroups.contains(group) },
                            set: { if $0 { expandedGroups.insert(group) } else { expandedGroups.remove(group) } }
                        )) {
                            ForEach(categories) { category in
                                MainSidebarNavigationLabel(
                                    title: category.label,
                                    systemImage: category.systemImage,
                                    isSelected: selection == category
                                )
                                .tag(category)
                            }
                        } header: {
                            Text(group.label)
                        }
                    }
                }
                if !SettingsGroup.allCases.flatMap(\.categories).contains(where: { $0.matches(searchText) }) {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: searchText) { _, query in
                if !query.isEmpty { expandedGroups = Set(SettingsGroup.allCases) }
            }
            .onChange(of: selection, initial: true) { _, category in
                if let group = SettingsGroup.allCases.first(where: { $0.categories.contains(category) }) {
                    expandedGroups.insert(group)
                }
            }

            MainSidebarFooterView(
                vaults: vaults,
                currentVault: currentVault,
                updateController: updateController,
                onSelectVault: onSelectVault
            )
        }
    }
}
