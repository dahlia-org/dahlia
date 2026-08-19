import SwiftUI

struct ProjectDetailDisplayModePicker: View {
    let displayMode: ProjectDetailDisplayMode
    let onChange: (ProjectDetailDisplayMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.list, label: L10n.list, systemImage: "list.bullet")
            modeButton(.calendar, label: L10n.calendar, systemImage: "calendar")
        }
        .padding(3)
        .background(DahliaDesign.contentHighlightColor, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.projectDetailDisplay)
    }

    private func modeButton(
        _ mode: ProjectDetailDisplayMode,
        label: String,
        systemImage: String
    ) -> some View {
        let isSelected = displayMode == mode
        return DahliaWindowHeaderIconButton(
            label: label,
            systemImage: systemImage,
            showsHoverHighlight: false,
            presentsHelpInContainerOverlay: true,
            controlSize: 22,
            action: { onChange(mode) }
        )
        .font(.callout)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .frame(width: 28, height: 22)
        .background(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear, in: Capsule())
        .overlay {
            if isSelected {
                Capsule().stroke(.separator)
            }
        }
        .contentShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
