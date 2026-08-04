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
                }

                if request.reviewability != .ready {
                    Text(reviewabilityMessage)
                        .font(.caption)
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
                        .font(.system(.body, design: .monospaced))
                }
                if let cwd = request.cwd {
                    Text(cwd)
                        .font(.system(.caption, design: .monospaced))
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
                ForEach(Array(request.fileChanges.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(change.path)
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                        if !change.diff.isEmpty {
                            Text(change.diff)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let grantRoot = request.grantRoot {
                    Text(grantRoot)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .approvalDetailRegion()
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
