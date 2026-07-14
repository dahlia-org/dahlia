import SwiftUI

struct CalendarEventMetadataButton: View {
    let text: String
    let event: CalendarEventDisplayInfo
    private let attributedDescription: AttributedString?

    @State private var isPresented = false

    init(text: String, event: CalendarEventDisplayInfo) {
        self.text = text
        self.event = event
        attributedDescription = event.description.nilIfBlank.map(CalendarEventDescriptionFormatter.attributedString)
    }

    var body: some View {
        Button(action: togglePresentation) {
            Label {
                Text(text)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            } icon: {
                Image(systemName: "calendar")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(L10n.calendarEventOrigin(event.resolvedTitle))
        .accessibilityLabel(L10n.calendarEventOrigin(event.resolvedTitle))
        .accessibilityValue(detailLines.joined(separator: ", "))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label(event.resolvedTitle, systemImage: "calendar")
                    .font(.headline)

                Text(dateText)
                    .foregroundStyle(.secondary)

                if let attributedDescription {
                    Text(attributedDescription)
                        .textSelection(.enabled)
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 360, alignment: .leading)
            .padding()
        }
    }

    private func togglePresentation() {
        isPresented.toggle()
    }

    private var detailLines: [String] {
        [dateText, attributedDescription.map { String($0.characters) }]
            .compactMap(\.self)
    }

    private var dateText: String {
        if event.isAllDay {
            return allDayDateText
        }

        let startDate = event.startDate.formatted(date: .abbreviated, time: .shortened)
        let endDate = if Calendar.autoupdatingCurrent.isDate(event.startDate, inSameDayAs: event.endDate) {
            event.endDate.formatted(date: .omitted, time: .shortened)
        } else {
            event.endDate.formatted(date: .abbreviated, time: .shortened)
        }
        return "\(startDate) – \(endDate)"
    }

    private var allDayDateText: String {
        let startDate = event.startDate.formatted(date: .abbreviated, time: .omitted)
        let inclusiveEndDate = if event.endDate > event.startDate {
            event.endDate.addingTimeInterval(-1)
        } else {
            event.endDate
        }
        if Calendar.autoupdatingCurrent.isDate(event.startDate, inSameDayAs: inclusiveEndDate) {
            return "\(startDate) · \(L10n.calendarAllDay)"
        }
        let endDate = inclusiveEndDate.formatted(date: .abbreviated, time: .omitted)
        return "\(startDate) – \(endDate) · \(L10n.calendarAllDay)"
    }
}
