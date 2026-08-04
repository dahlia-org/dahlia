import SwiftUI

struct CodexChatApprovalView: View {
    let request: CodexChatApprovalRequest
    let onDecide: (CodexChatApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: "hand.raised")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if hasDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let reason = request.reason {
                            Text(reason)
                                .font(.body)
                        }

                        requestDetails
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }

            CodexChatApprovalActions(request: request, onDecide: onDecide)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: CodexChatDesign.composerCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: CodexChatDesign.composerCornerRadius)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
    }

    private var title: String {
        switch request.kind {
        case .commandExecution:
            L10n.chatApprovalCommandTitle
        case .fileChange:
            L10n.chatApprovalFileChangeTitle
        }
    }

    private var hasDetails: Bool {
        request.reason != nil
            || request.command != nil
            || request.cwd != nil
            || !request.fileChanges.isEmpty
            || request.grantRoot != nil
    }

    @ViewBuilder
    private var requestDetails: some View {
        switch request.kind {
        case .commandExecution:
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
                .detailRegionStyle()
            }
        case .fileChange:
            if !request.fileChanges.isEmpty || request.grantRoot != nil {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(request.fileChanges.indices, id: \.self) { index in
                        let change = request.fileChanges[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.path)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                            if let diff = change.diff.nilIfBlank {
                                Text(CodexChatApprovalDiffPreview.text(for: diff))
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
                .detailRegionStyle()
            }
        }
    }
}

enum CodexChatApprovalDiffPreview {
    static let byteLimit = 20000

    static func text(for diff: String) -> String {
        let prefix = diff.utf8.prefix(byteLimit + 1)
        guard prefix.count > byteLimit else { return diff }
        return String(decoding: prefix.dropLast(), as: UTF8.self) + "\n…"
    }
}

private struct CodexChatApprovalActions: View {
    let request: CodexChatApprovalRequest
    let onDecide: (CodexChatApprovalDecision) -> Void

    var body: some View {
        if request.canApprove {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Spacer()
                    denyButton
                    sessionApprovalButton
                    allowOnceButton
                }

                VStack(alignment: .trailing, spacing: 8) {
                    sessionApprovalButton
                    HStack(spacing: 8) {
                        denyButton
                        allowOnceButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack {
                Spacer()
                denyButton
            }
        }
    }

    private var denyButton: some View {
        CodexChatApprovalSecondaryButton(
            title: L10n.chatApprovalDeny,
            action: { onDecide(.decline) }
        )
    }

    private var sessionApprovalTitle: String {
        switch request.kind {
        case .commandExecution:
            L10n.chatApprovalAllowSimilarCommands
        case .fileChange:
            L10n.chatApprovalAlwaysAllow
        }
    }

    private var sessionApprovalButton: some View {
        CodexChatApprovalSecondaryButton(
            title: sessionApprovalTitle,
            action: { onDecide(.acceptForSession) }
        )
    }

    private var allowOnceButton: some View {
        CodexChatApprovalPrimaryButton(
            title: L10n.chatApprovalAllowOnce,
            action: { onDecide(.accept) }
        )
    }
}

private struct CodexChatApprovalPrimaryButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .foregroundStyle(.white)
            .background(.primary.opacity(isHovering ? 0.72 : 0.85), in: Capsule())
            .onHover { isHovering = $0 }
    }
}

private struct CodexChatApprovalSecondaryButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.secondary.opacity(0.25), lineWidth: 1)
            }
            .onHover { isHovering = $0 }
    }
}

private extension View {
    func detailRegionStyle() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
