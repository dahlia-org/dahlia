import SwiftUI

struct CodexChatApprovalView: View {
    let request: CodexChatApprovalRequest
    let onDecide: (CodexChatApprovalDecision) -> Void

    var body: some View {
        let approvalDetail = detail
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "hand.raised.fill")
                .font(.callout)
                .foregroundStyle(.primary)
            if approvalDetail != nil || request.reason != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let approvalDetail {
                            Text(approvalDetail)
                                .font(.system(.caption, design: .monospaced))
                        }
                        if let reason = request.reason {
                            Text(reason)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                }
                .frame(maxHeight: 180)
            }
            HStack {
                if request.canApprove {
                    Button(L10n.chatApprovalAllow) { onDecide(.accept) }
                    Button(L10n.chatApprovalAlwaysAllow) { onDecide(.acceptForSession) }
                }
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
            fileChangeDetail
        }
    }

    private var fileChangeDetail: String? {
        let changes = request.fileChanges.flatMap { change in
            [change.path, change.diff.nilIfBlank].compactMap(\.self)
        }
        return (changes + [request.grantRoot].compactMap(\.self))
            .joined(separator: "\n\n")
            .nilIfBlank
    }
}
