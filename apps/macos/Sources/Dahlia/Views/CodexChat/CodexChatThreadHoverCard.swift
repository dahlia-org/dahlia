import SwiftUI

struct CodexChatThreadHoverCard: View {
    let thread: CodexChatThreadSummary
    let title: String
    let firstMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.dahliaHeadline)
                .lineLimit(1)
            if let model = thread.modelDisplayName {
                Label {
                    Text(model)
                } icon: {
                    Image.piLogo.resizable().scaledToFit().frame(width: 14, height: 14)
                }
                .font(.dahliaSecondary)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .lineLimit(1)
            }
            HStack {
                Label(L10n.chatRunStatus(thread.status), systemImage: thread.status == "completed" ? "checkmark" : "circle.fill")
                    .foregroundStyle(thread.status == "completed" ? Color.green : DahliaDesign.secondaryTextColor)
                Spacer()
                if let startedAt = thread.startedAt, let completedAt = thread.completedAt {
                    Text(Duration.seconds(max(0, completedAt.timeIntervalSince(startedAt))).formatted(
                        .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
                    ))
                } else if let completedAt = thread.completedAt {
                    Text(completedAt, format: .dateTime.hour().minute())
                }
            }
            .font(.dahliaSecondary)
            .foregroundStyle(DahliaDesign.secondaryTextColor)
            if !firstMessage.isEmpty {
                Label(firstMessage, systemImage: "terminal")
                    .font(.dahliaSecondary)
                    .lineLimit(1)
            }
        }
        .font(.dahliaSecondary)
        .foregroundStyle(DahliaDesign.primaryTextColor)
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.15)) }
        .fixedSize(horizontal: false, vertical: true)
    }
}
