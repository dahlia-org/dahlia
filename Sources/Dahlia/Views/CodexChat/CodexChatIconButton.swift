import SwiftUI

struct CodexChatIconButton: View {
    let label: String
    let systemImage: String
    var size = CodexChatDesign.headerControlSize
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(label, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: size, height: size)
            .background(
                isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .help(label)
    }
}
