import SwiftUI

struct CodexChatThreadStatusView: View {
    let thread: CodexChatThreadSummary
    let activity: CodexChatThreadActivity?

    var body: some View {
        Group {
            switch activity {
            case .queued:
                Label(L10n.chatRunStatus("queued"), systemImage: "clock")
            case .running:
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(L10n.chatThreadRunningShort)
                }
                .foregroundStyle(Color.accentColor)
            case .waitingForUser:
                Label(L10n.chatThreadWaitingShort, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            case nil:
                if thread.hasUnseenCompletion {
                    Label(L10n.chatRunStatus("completed"), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if let lastResponseAt = thread.lastResponseAt {
                    Text(lastResponseAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .foregroundStyle(DahliaDesign.optionalTextColor)
                }
            }
        }
        .font(.dahliaSecondary)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}
