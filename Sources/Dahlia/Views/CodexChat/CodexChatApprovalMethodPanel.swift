import AppKit
import SwiftUI

struct CodexChatApprovalMethodPanel: View {
    @Bindable var session: CodexChatSessionModel
    let width: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.chatApprovalMethod)
                .font(.body)
                .foregroundStyle(DahliaDesign.optionalTextColor)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)

            ForEach(CodexChatApprovalMethod.allCases) { method in
                CodexChatApprovalMethodRow(
                    method: method,
                    isSelected: method == session.selectedApprovalMethod,
                    isEnabled: method != .autoReview || session.canUseAutoReview,
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
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let calloutFont = NSFont.preferredFont(forTextStyle: .callout)
        let widestTextWidth = CodexChatApprovalMethod.allCases.reduce(0) { width, method in
            let methodWidth = max(
                textWidth(method.title, font: bodyFont),
                textWidth(method.description, font: calloutFont)
            )
            let availabilityWidth = method == .autoReview
                ? textWidth(L10n.chatApprovalAutoReviewRequiresSubscription, font: calloutFont)
                : 0
            return max(width, max(methodWidth, availabilityWidth))
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
