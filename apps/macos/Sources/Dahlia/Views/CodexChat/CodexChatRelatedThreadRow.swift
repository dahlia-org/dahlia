import SwiftUI

struct CodexChatRelatedThreadRow: View {
    let thread: CodexChatThreadSummary
    let meetingNamesByID: [UUID: String]
    let onOpen: () -> Void
    var onStop: (() -> Void)?
    var isNotification = false

    @State private var isHovered = false
    @State private var hoverController = DahliaWindowHeaderHelpController()
    @State private var hoverID = UUID()

    private var title: String {
        CodexChatMeetingReference.displayText(for: thread.title.nilIfBlank ?? L10n.newChat, namesByID: meetingNamesByID)
    }

    private var firstMessage: String {
        CodexChatMeetingReference.displayText(for: thread.firstMessage ?? "", namesByID: meetingNamesByID)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image.piLogo
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .overlay(alignment: .bottomTrailing) {
                            if let statusColor {
                                Circle().fill(statusColor)
                                    .frame(width: 8, height: 8)
                                    .overlay { Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1) }
                            }
                        }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.dahliaBody)
                            .lineLimit(1)
                        Text(firstMessage.nilIfBlank ?? " ")
                            .font(.dahliaSecondary)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    trailingStatus
                    Image(systemName: "chevron.right")
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(.rect)
                .background(isHovered ? DahliaDesign.contentHighlightColor : .clear, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityValue(L10n.chatRunStatus(thread.status))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    hoverController.hoverBegan(for: hoverID)
                } else {
                    hoverController.hoverEnded(for: hoverID)
                }
            }
            .background {
                CodexChatThreadHoverPanel(isPresented: hoverController.visibleHelpID == hoverID) {
                    CodexChatThreadHoverCard(thread: thread, title: title, firstMessage: firstMessage)
                }
            }

            if !isNotification, let onStop, ["queued", "running", "waitingForUser"].contains(thread.status) {
                Button(L10n.stopGenerating, systemImage: "stop.fill", action: onStop)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(.trailing, 10)
            }
        }
        .onDisappear { hoverController.dismissAll() }
    }

    private var statusColor: Color? {
        switch thread.status {
        case "queued", "running", "waitingForUser": .blue
        case "completed": .green
        case "failed": .red
        case "interrupted": .orange
        default: nil
        }
    }

    private var trailingStatus: some View {
        Group {
            if isNotification {
                HStack(spacing: 6) {
                    Text(L10n.chatRunStatus(thread.status))
                    if let completedAt = thread.completedAt {
                        Text(completedAt, format: .dateTime.hour().minute())
                    }
                }
            } else if let startedAt = thread.startedAt {
                if let completedAt = thread.completedAt {
                    Text(elapsed(from: startedAt, to: completedAt))
                } else if ["queued", "running", "waitingForUser"].contains(thread.status) {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(elapsed(from: startedAt, to: context.date))
                    }
                } else {
                    Text(L10n.chatRunStatus(thread.status))
                }
            } else {
                Text(L10n.chatRunStatus(thread.status))
            }
        }
        .font(.dahliaSecondary)
        .foregroundStyle(DahliaDesign.secondaryTextColor)
        .monospacedDigit()
        .fixedSize()
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        Duration.seconds(max(0, end.timeIntervalSince(start))).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        )
    }
}
