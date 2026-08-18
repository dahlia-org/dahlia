import SwiftUI

struct CodexChatApprovalView: View {
    let request: CodexChatApprovalRequest
    let isDecisionEnabled: Bool
    let onDecide: (String, CodexChatApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: "hand.raised")
                .dahliaFont(.body, weight: .medium)
                .foregroundStyle(.secondary)

            CodexChatApprovalDetails(request: request)

            CodexChatApprovalActions(
                request: request,
                isDecisionEnabled: isDecisionEnabled,
                onDecide: onDecide
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: .rect(cornerRadius: CodexChatDesign.composerCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: CodexChatDesign.composerCornerRadius)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
    }

    private var title: String {
        switch request.kind {
        case .commandExecution: L10n.chatApprovalCommandTitle
        case .fileChange: L10n.chatApprovalFileChangeTitle
        case .mcpToolCall: L10n.chatApprovalMCPToolTitle
        }
    }
}
