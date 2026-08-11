import SwiftUI

struct CodexChatIconButton: View {
    let label: String
    let systemImage: String
    var size = CodexChatDesign.headerControlSize
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // クリック判定はラベルの形で決まる。frame と contentShape をボタンの外に置くと
            // グリフの矩形しか反応せず、minus のように背の低い記号はほとんど押せなくなる。
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { isHovering = $0 }
        .help(label)
    }
}
