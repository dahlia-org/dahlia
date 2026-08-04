import SwiftUI

struct CodexChatApprovalView: View {
    let request: CodexChatApprovalRequest
    let onDecide: (CodexChatApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "hand.raised.fill")
                .font(.callout)
                .foregroundStyle(.primary)
            if let detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
            }
            if let reason = request.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.chatApprovalAllow) { onDecide(.accept) }
                Button(L10n.chatApprovalAlwaysAllow) { onDecide(.acceptForSession) }
                Button(L10n.chatApprovalDeny) { onDecide(.decline) }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.vertical, 6)
    }

    private var title: String {
        switch request.kind {
        case .commandExecution:
            L10n.chatApprovalCommandTitle
        case .fileChange:
            L10n.chatApprovalFileChangeTitle
        }
    }

    private var detail: String? {
        switch request.kind {
        case .commandExecution:
            [request.command, request.cwd].compactMap(\.self).joined(separator: "\n").nilIfBlank
        case .fileChange:
            request.cwd
        }
    }
}
