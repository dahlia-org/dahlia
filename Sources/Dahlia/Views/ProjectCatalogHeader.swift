import SwiftUI

struct ProjectCatalogHeader: View {
    let sortField: ProjectCatalogView.SortField
    let sortAscending: Bool
    let onSort: (ProjectCatalogView.SortField) -> Void

    var body: some View {
        HStack(spacing: 12) {
            sortButton(L10n.name, field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortButton(L10n.updated, field: .updated)
                .frame(width: 120, alignment: .leading)
            Color.clear
                .frame(width: 80, height: 1)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func sortButton(_ title: String, field: ProjectCatalogView.SortField) -> some View {
        Button {
            onSort(field)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(sortField == field ? (sortAscending ? L10n.ascending : L10n.descending) : "")
    }
}
