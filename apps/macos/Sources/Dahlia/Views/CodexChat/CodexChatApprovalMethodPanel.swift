import AppKit
import SwiftUI

struct CodexChatApprovalMethodPanel: View {
    @Bindable var session: CodexChatSessionModel
    let width: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.chatApprovalMethod)
                .font(.dahliaBody)
                .foregroundStyle(DahliaDesign.optionalTextColor)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            ForEach(CodexChatApprovalMethod.allCases) { method in
                CodexChatApprovalMethodRow(
                    method: method,
                    isSelected: method == session.selectedApprovalMethod,
                    action: { select(method) }
                )
            }
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .codexChatPanelStyle()
    }

    private func select(_ method: CodexChatApprovalMethod) {
        session.selectApprovalMethod(method)
        onDismiss()
    }
}

enum CodexChatApprovalMethodPanelLayout {
    static let windowInset: CGFloat = 16

    static var preferredWidth: CGFloat {
        let font = NSFont.dahliaBody
        let widestTextWidth = CodexChatApprovalMethod.allCases.reduce(0) { width, method in
            let methodWidth = max(
                textWidth(method.title, font: font),
                textWidth(method.description, font: font)
            )
            return max(width, methodWidth)
        }
        return ceil(widestTextWidth + 100)
    }

    static func width(windowBounds: CGRect) -> CGFloat {
        guard windowBounds.width > 0 else { return preferredWidth }
        return min(preferredWidth, max(0, windowBounds.width - windowInset * 2))
    }

    static func horizontalOffset(windowBounds: CGRect, panelWidth: CGFloat) -> CGFloat {
        guard windowBounds.width > 0 else { return 0 }
        let minimumX = windowBounds.minX + windowInset
        let maximumX = windowBounds.maxX - windowInset - panelWidth
        return min(max(0, minimumX), maximumX)
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}
