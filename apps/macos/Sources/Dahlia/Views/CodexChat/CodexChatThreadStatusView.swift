import SwiftUI

struct CodexChatThreadStatusView: View {
    let thread: CodexChatThreadSummary
    let activity: CodexChatThreadActivity?

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Group {
            switch activity {
            case .queued:
                HStack(spacing: 2) {
                    Image(systemName: "clock")
                    Text(L10n.chatRunStatus("queued"))
                }
            case .running:
                HStack(spacing: 2) {
                    Image(systemName: "circle.dotted")
                        .symbolEffect(.rotate, isActive: !accessibilityReduceMotion)
                        .accessibilityHidden(true)
                    Text(L10n.chatThreadRunningShort)
                }
                .foregroundStyle(Color.accentColor)
            case .waitingForUser:
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle")
                    Text(L10n.chatThreadWaitingShort)
                }
                .foregroundStyle(.orange)
            case nil:
                if thread.hasUnseenCompletion {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle")
                        Text(L10n.done)
                    }
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
