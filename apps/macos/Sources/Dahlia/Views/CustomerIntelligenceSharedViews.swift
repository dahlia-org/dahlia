import SwiftUI

struct CustomerIntelligenceTopicRow: View {
    let topic: ConversationTopicOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.topic.title)
                .font(.headline)
            Text(topic.topic.currentState)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Label("\(topic.meetingCount)", systemImage: "calendar")
                Label("\(topic.organizationCount)", systemImage: "building.2")
                if let lastDiscussedAt = topic.lastDiscussedAt {
                    Text(lastDiscussedAt, style: .date)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

struct CustomerIntelligenceMeetingRow: View {
    let meeting: MeetingRecord
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.name)
            Text(meeting.effectiveRecordingStartedAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

extension View {
    func customerIntelligenceTableStyle() -> some View {
        tableStyle(.inset(alternatesRowBackgrounds: false))
    }

    func customerIntelligenceErrorAlert(
        title: String = L10n.customerIntelligenceUpdateError,
        message: Binding<String?>
    ) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button(L10n.close, role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
