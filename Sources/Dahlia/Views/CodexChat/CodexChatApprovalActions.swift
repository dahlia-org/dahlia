import SwiftUI

struct CodexChatApprovalActions: View {
    let request: CodexChatApprovalRequest
    let isDecisionEnabled: Bool
    let onDecide: (String, CodexChatApprovalDecision) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                denyButton
                Spacer()
                approvalButtons
            }

            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    denyButton
                    Spacer()
                }
                approvalButtons
            }
        }
    }

    private var denyButton: some View {
        CodexChatApprovalButton(
            title: L10n.chatApprovalDeny,
            prominence: .secondary,
            isEnabled: isDecisionEnabled,
            action: { onDecide(request.id, request.rejectionDecision) }
        )
    }

    private var approvalButtons: some View {
        HStack(spacing: 8) {
            ForEach(approvalActions) { action in
                CodexChatApprovalButton(
                    title: title(for: action),
                    helpText: helpText(for: action),
                    prominence: action == .allowOnce ? .primary : .secondary,
                    isEnabled: isDecisionEnabled,
                    action: { onDecide(request.id, action.decision) }
                )
            }
        }
    }

    private var approvalActions: [CodexChatApprovalAction] {
        let actions = request.actions.filter { $0 != .deny }
        return actions.filter { $0 != .allowOnce } + actions.filter { $0 == .allowOnce }
    }

    private func title(for action: CodexChatApprovalAction) -> String {
        switch action {
        case .allowOnce: L10n.chatApprovalAllowOnce
        case .allowSameFilesForSession: L10n.chatApprovalAllowSameFiles
        case .allowSimilarCommands: L10n.chatApprovalAllowSimilarCommands
        case .deny: L10n.chatApprovalDeny
        }
    }

    private func helpText(for action: CodexChatApprovalAction) -> String? {
        guard case let .allowSimilarCommands(amendment) = action else { return nil }
        return "\(L10n.chatApprovalSimilarCommandScope)\n\(amendment.joined(separator: " "))"
    }
}
