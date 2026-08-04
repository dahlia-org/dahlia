import SwiftUI

struct CodexChatApprovalView: View {
    let request: CodexChatApprovalRequest
    let onDecide: (CodexChatApprovalDecision) -> Void
    let onStop: () -> Void

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

            CodexChatApprovalActions(request: request, onDecide: onDecide, onStop: onStop)
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
                let preview = CodexChatApprovalDiffPreview.projection(for: request.fileChanges)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.items.indices, id: \.self) { index in
                        let item = preview.items[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.path)
                                .font(.system(.caption, design: .monospaced).weight(.medium))
                            if let diff = item.diff {
                                Text(diff)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if preview.isTruncated {
                        Text("…")
                            .foregroundStyle(.secondary)
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
    struct Item: Equatable {
        let path: String
        let diff: String?
    }

    struct Projection: Equatable {
        let items: [Item]
        let isTruncated: Bool
    }

    static let byteLimit = 20000
    static let fileLimit = 50

    static func projection(for changes: [CodexChatApprovalRequest.FileChange]) -> Projection {
        var items: [Item] = []
        var remainingBytes = byteLimit
        var isTruncated = changes.count > fileLimit

        for change in changes.prefix(fileLimit) {
            let path = bounded(change.path, byteLimit: remainingBytes)
            guard !path.text.isEmpty else {
                isTruncated = true
                break
            }
            remainingBytes -= path.byteCount

            var diff: String?
            if let rawDiff = change.diff.nilIfBlank {
                let boundedDiff = bounded(rawDiff, byteLimit: remainingBytes)
                diff = boundedDiff.text.nilIfBlank
                remainingBytes -= boundedDiff.byteCount
                isTruncated = isTruncated || boundedDiff.isTruncated
            }
            items.append(Item(path: path.text, diff: diff))
            isTruncated = isTruncated || path.isTruncated

            if remainingBytes == 0, items.count < changes.count {
                isTruncated = true
                break
            }
        }

        return Projection(items: items, isTruncated: isTruncated)
    }

    private static func bounded(_ text: String, byteLimit: Int) -> (text: String, byteCount: Int, isTruncated: Bool) {
        guard text.utf8.count > byteLimit else { return (text, text.utf8.count, false) }
        guard byteLimit >= 3 else { return ("", 0, true) }

        let contentLimit = byteLimit - 3
        let scalars = text.unicodeScalars
        var end = scalars.startIndex
        var byteCount = 0
        while end < scalars.endIndex {
            let scalar = scalars[end]
            guard byteCount + scalar.utf8.count <= contentLimit else { break }
            byteCount += scalar.utf8.count
            end = scalars.index(after: end)
        }
        let truncated = String(scalars[..<end]) + "…"
        return (truncated, byteCount + 3, true)
    }
}

private struct CodexChatApprovalActions: View {
    let request: CodexChatApprovalRequest
    let onDecide: (CodexChatApprovalDecision) -> Void
    let onStop: () -> Void

    var body: some View {
        if request.canApprove {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    stopButton
                    Spacer()
                    denyButton
                    sessionApprovalButton
                    allowOnceButton
                }

                VStack(alignment: .trailing, spacing: 8) {
                    HStack {
                        stopButton
                        Spacer()
                        sessionApprovalButton
                    }
                    HStack(spacing: 8) {
                        denyButton
                        allowOnceButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack {
                stopButton
                Spacer()
                denyButton
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
