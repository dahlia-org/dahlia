import SwiftUI

struct CodexChatApprovalActions: View {
    let request: CodexChatApprovalRequest
    let isResponding: Bool
    let onDecide: (String, CodexChatApprovalDecision) -> Void
    let onStop: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                stopButton
                Spacer()
                decisionButtons
            }

            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    stopButton
                    Spacer()
                }
                decisionButtons
            }
        }
    }

    private var stopButton: some View {
        CodexChatActionButton(
            label: L10n.stopGenerating,
            systemImage: "stop.fill",
            isEnabled: true,
            action: onStop
        )
    }

    private var decisionButtons: some View {
        HStack(spacing: 8) {
            ForEach(request.actions) { action in
                CodexChatApprovalButton(
                    title: title(for: action),
                    prominence: action == .allowOnce ? .primary : .secondary,
                    isEnabled: !isResponding,
                    action: { onDecide(request.id, action.decision) }
                )
            }
        }
    }

    private func title(for action: CodexChatApprovalAction) -> String {
        switch action {
        case .allowOnce: L10n.chatApprovalAllowOnce
        case .allowForSession: L10n.chatApprovalAlwaysAllow
        case .allowSimilarCommands: L10n.chatApprovalAllowSimilarCommands
        case .deny: L10n.chatApprovalDeny
        }
    }
}
