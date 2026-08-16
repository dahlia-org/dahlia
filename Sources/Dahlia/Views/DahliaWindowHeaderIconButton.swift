import SwiftUI

struct DahliaWindowHeaderIconButton: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(
                    width: DahliaDesign.windowHeaderControlSize,
                    height: DahliaDesign.windowHeaderControlSize
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 8)
        )
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
