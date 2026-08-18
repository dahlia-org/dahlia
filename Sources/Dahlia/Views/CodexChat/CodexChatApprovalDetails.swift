import SwiftUI

struct CodexChatApprovalDetails: View {
    let request: CodexChatApprovalRequest

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let reason = request.reason {
                    Text(reason)
                        .dahliaFont(.body)
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
                        .dahliaFont(.secondary)
                        .foregroundStyle(.secondary)
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
                        .dahliaFont(.body, design: .monospaced)
                }
                if let cwd = request.cwd {
                    Text(cwd)
                        .dahliaFont(.secondary, design: .monospaced)
                        .foregroundStyle(.secondary)
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
                        .dahliaFont(.body, weight: .medium, design: .monospaced)
                }
                if let arguments = request.mcpArguments {
                    Text(arguments)
                        .dahliaFont(.secondary, design: .monospaced)
                        .foregroundStyle(.secondary)
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
                            .dahliaFont(.secondary, weight: .medium, design: .monospaced)
                        if !change.diff.isEmpty {
                            Text(change.diff)
                                .dahliaFont(.secondary, design: .monospaced)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let grantRoot = request.grantRoot {
                    Text(grantRoot)
                        .dahliaFont(.secondary, design: .monospaced)
                        .foregroundStyle(.secondary)
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
