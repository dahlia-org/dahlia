import CoreGraphics

enum CodexChatSlashCommandLayout {
    static func width(in bounds: CGRect) -> CGFloat {
        min(320, bounds.width > 0 ? max(0, bounds.width - 16) : 320)
    }

    static func maximumHeight(in bounds: CGRect, composerHeight: CGFloat) -> CGFloat {
        guard bounds.height > 0 else { return 240 }
        return max(0, min(240, max(-bounds.minY - 16, bounds.maxY - composerHeight - 16)))
    }

    static func offset(panelSize: CGSize, in bounds: CGRect, composerHeight: CGFloat) -> CGSize {
        guard bounds.height > 0 else { return CGSize(width: 0, height: -panelSize.height - 8) }
        let above = -bounds.minY - 16
        let below = bounds.maxY - composerHeight - 16
        let y = above >= panelSize.height || above >= below ? -panelSize.height - 8 : composerHeight + 8
        return CGSize(
            width: min(max(0, bounds.minX + 8), bounds.maxX - panelSize.width - 8),
            height: min(max(y, bounds.minY + 8), bounds.maxY - panelSize.height - 8)
        )
    }
}
