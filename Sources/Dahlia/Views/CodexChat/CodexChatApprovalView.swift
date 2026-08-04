import SwiftUI

struct CodexChatApprovalView: View {
    let request: CodexChatApprovalRequest
    let onDecide: (CodexChatApprovalDecision) -> Void
    let onStop: () -> Void

    @State private var isCompleteReviewAvailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: "hand.raised")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if hasDetails {
                CodexChatApprovalDetails(
                    request: request,
                    onReviewAvailabilityChange: { isCompleteReviewAvailable = $0 }
                )
            }

            CodexChatApprovalActions(
                request: request,
                isCompleteReviewAvailable: isCompleteReviewAvailable,
                onDecide: onDecide,
                onStop: onStop
            )
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

}

enum CodexChatApprovalDetailsProjection {
    struct Item: Equatable, Sendable {
        let path: String
        let diff: String?
    }

    struct Projection: Equatable, Sendable {
        let reason: String?
        let command: String?
        let cwd: String?
        let fileChanges: [Item]
        let areFileChangesTruncated: Bool
        let grantRoot: String?
        let isTruncated: Bool
    }

    static let byteLimit = 20000
    static let fileLimit = 50

    static func projection(for request: CodexChatApprovalRequest) -> Projection {
        let sectionCount = [
            request.reason != nil,
            request.command != nil,
            request.cwd != nil,
            !request.fileChanges.isEmpty,
            request.grantRoot != nil,
        ].count(where: { $0 })
        let sectionByteLimit = sectionCount > 0 ? byteLimit / sectionCount : byteLimit
        let fileChanges = fileChangeProjection(for: request.fileChanges, byteLimit: sectionByteLimit)

        let reason = textProjection(for: request.reason, byteLimit: sectionByteLimit)
        let command = textProjection(for: request.command, byteLimit: sectionByteLimit)
        let cwd = textProjection(for: request.cwd, byteLimit: sectionByteLimit)
        let grantRoot = textProjection(for: request.grantRoot, byteLimit: sectionByteLimit)

        return Projection(
            reason: reason.text,
            command: command.text,
            cwd: cwd.text,
            fileChanges: fileChanges.items,
            areFileChangesTruncated: fileChanges.isTruncated,
            grantRoot: grantRoot.text,
            isTruncated: reason.isTruncated
                || command.isTruncated
                || cwd.isTruncated
                || fileChanges.isTruncated
                || grantRoot.isTruncated
        )
    }

    private static func textProjection(for text: String?, byteLimit: Int) -> (text: String?, isTruncated: Bool) {
        guard let text else { return (nil, false) }
        let bounded = bounded(text, byteLimit: byteLimit)
        return (bounded.text.nilIfBlank, bounded.isTruncated)
    }

    private static func fileChangeProjection(
        for changes: [CodexChatApprovalRequest.FileChange],
        byteLimit: Int
    ) -> (items: [Item], isTruncated: Bool) {
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
            let boundedDiff = bounded(change.diff, byteLimit: remainingBytes)
            diff = boundedDiff.text.nilIfBlank
            remainingBytes -= boundedDiff.byteCount
            isTruncated = isTruncated || boundedDiff.isTruncated
            items.append(Item(path: path.text, diff: diff))
            isTruncated = isTruncated || path.isTruncated

            if remainingBytes == 0, items.count < changes.count {
                isTruncated = true
                break
            }
        }

        return (items, isTruncated)
    }

    private static func bounded(_ text: String, byteLimit: Int) -> (text: String, byteCount: Int, isTruncated: Bool) {
        let boundedBytes = text.utf8.prefix(byteLimit + 1)
        guard boundedBytes.count > byteLimit else { return (text, boundedBytes.count, false) }
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

private struct CodexChatApprovalDetails: View {
    let request: CodexChatApprovalRequest
    let onReviewAvailabilityChange: (Bool) -> Void

    @State private var projection: CodexChatApprovalDetailsProjection.Projection?

    var body: some View {
        ScrollView {
            if let projection {
                VStack(alignment: .leading, spacing: 12) {
                    if let reason = projection.reason {
                        Text(reason)
                            .font(.body)
                    }

                    requestDetails(projection)

                    if projection.isTruncated {
                        Text(L10n.chatApprovalDetailsTooLarge)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: 180)
        .task(id: request.id) {
            projection = nil
            onReviewAvailabilityChange(false)
            let request = request
            let projection = await Task.detached(priority: .userInitiated) {
                CodexChatApprovalDetailsProjection.projection(for: request)
            }.value
            guard !Task.isCancelled else { return }
            self.projection = projection
            onReviewAvailabilityChange(!projection.isTruncated)
        }
    }

    @ViewBuilder
    private func requestDetails(_ projection: CodexChatApprovalDetailsProjection.Projection) -> some View {
        switch request.kind {
        case .commandExecution:
            if projection.command != nil || projection.cwd != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let command = projection.command {
                        Text(command)
                            .font(.system(.body, design: .monospaced))
                    }
                    if let cwd = projection.cwd {
                        Text(cwd)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .detailRegionStyle()
            }
        case .fileChange:
            if !projection.fileChanges.isEmpty || projection.grantRoot != nil {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(projection.fileChanges.indices, id: \.self) { index in
                        let item = projection.fileChanges[index]
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
                    if projection.areFileChangesTruncated {
                        Text("…")
                            .foregroundStyle(.secondary)
                    }
                    if let grantRoot = projection.grantRoot {
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

private struct CodexChatApprovalActions: View {
    let request: CodexChatApprovalRequest
    let isCompleteReviewAvailable: Bool
    let onDecide: (CodexChatApprovalDecision) -> Void
    let onStop: () -> Void

    var body: some View {
        if hasReviewablePayload, isCompleteReviewAvailable {
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

    private var hasReviewablePayload: Bool {
        switch request.kind {
        case .commandExecution:
            request.command != nil
        case .fileChange:
            !request.fileChanges.isEmpty
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
