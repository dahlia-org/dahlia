import SwiftUI

struct CodexChatApprovalDetails: View {
    let request: CodexChatApprovalRequest

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let reason = request.reason {
                    Text(reason)
                        .font(.body)
                }

                switch request.kind {
                case .commandExecution:
                    CodexChatCommandApprovalDetails(request: request)
                case .fileChange:
                    CodexChatFileApprovalDetails(request: request)
                case .mcpToolCall:
                    CodexChatMCPApprovalDetails(request: request)
                }

                if request.reviewability != .ready {
                    Text(reviewabilityMessage)
                        .font(.footnote)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 180)
    }

    private var reviewabilityMessage: String {
        switch request.reviewability {
        case .ready: ""
        case .tooLarge: L10n.chatApprovalDetailsTooLarge
        case .unsupported: L10n.chatApprovalUnsupportedScope
        }
    }
}

private struct CodexChatCommandApprovalDetails: View {
    let request: CodexChatApprovalRequest

    var body: some View {
        if request.command != nil || request.cwd != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let command = request.command {
                    Text(command)
                        .font(.body.monospaced())
                }
                if let cwd = request.cwd {
                    Text(cwd)
                        .font(.footnote.monospaced())
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }
            .approvalDetailRegion()
        }

    }
}

private struct CodexChatMCPApprovalDetails: View {
    let request: CodexChatApprovalRequest

    var body: some View {
        if request.mcpServer != nil || request.mcpTool != nil || request.mcpArguments != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let server = request.mcpServer, let tool = request.mcpTool {
                    Text("\(server).\(tool)")
                        .font(.body.weight(.medium).monospaced())
                }
                if let arguments = request.mcpArguments {
                    Text(arguments)
                        .font(.footnote.monospaced())
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }
            .approvalDetailRegion()
        }
    }
}

private struct CodexChatFileApprovalDetails: View {
    let request: CodexChatApprovalRequest

    var body: some View {
        if !request.fileChanges.isEmpty || request.grantRoot != nil {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(request.fileChanges.enumerated(), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(for: change))
                            .font(.footnote.weight(.medium).monospaced())
                        if !change.diff.isEmpty {
                            Text(change.diff)
                                .font(.footnote.monospaced())
                                .foregroundStyle(DahliaDesign.secondaryTextColor)
                        }
                    }
                }
                if let grantRoot = request.grantRoot {
                    Text(grantRoot)
                        .font(.footnote.monospaced())
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }
            .approvalDetailRegion()
        }
    }

    private func title(for change: CodexChatApprovalRequest.FileChange) -> String {
        switch change.kind {
        case .add:
            L10n.chatApprovalAddFile(change.path)
        case .delete:
            L10n.chatApprovalDeleteFile(change.path)
        case let .update(movePath: .some(movePath)):
            L10n.chatApprovalMoveFile(change.path, to: movePath)
        case .update(movePath: nil):
            L10n.chatApprovalUpdateFile(change.path)
        }
    }
}

private extension View {
    func approvalDetailRegion() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: .rect(cornerRadius: 10))
    }
}
