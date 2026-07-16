import SwiftUI

struct ScreenshotManagementToolbar: View {
    @Binding var minimumWidth: Double
    @Binding var isSelecting: Bool
    let selectedCount: Int
    let canSelectAll: Bool
    let isDeletionDisabled: Bool
    let selectAll: () -> Void
    let deleteSelected: () -> Void

    var body: some View {
        HStack {
            Slider(
                value: $minimumWidth,
                in: ScreenshotGridSizing.minimumWidth ... ScreenshotGridSizing.maximumWidth
            ) {
                Text(L10n.layout)
            } minimumValueLabel: {
                Image(systemName: "square.grid.3x3")
                    .accessibilityLabel(L10n.small)
            } maximumValueLabel: {
                Image(systemName: "rectangle.grid.1x2")
                    .accessibilityLabel(L10n.large)
            }
            .frame(minWidth: 140, maxWidth: 220)
            .help(L10n.layout)

            Spacer()

            if isSelecting {
                Text(L10n.selectedCount(selectedCount))
                    .foregroundStyle(.secondary)

                Button(L10n.selectAll, action: selectAll)
                    .disabled(!canSelectAll)

                Button(L10n.delete, systemImage: "trash", role: .destructive, action: deleteSelected)
                    .disabled(selectedCount == 0 || isDeletionDisabled)
            }

            Button(isSelecting ? L10n.done : L10n.select) {
                isSelecting.toggle()
            }
            .disabled(!isSelecting && isDeletionDisabled)
        }
        .buttonStyle(.bordered)
    }
}
