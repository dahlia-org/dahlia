import SwiftUI

struct CalendarEventMetadataButton: View {
    let text: String
    let event: CalendarEventDisplayInfo

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var attributedDescription: AttributedString?
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button(action: togglePresentation) {
            Label {
                Text(text)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            } icon: {
                Image(systemName: "calendar")
                    .font(.caption2)
            }
            .foregroundStyle(DahliaDesign.secondaryTextColor)
            .dahliaChipSurface(isHovered: isHovered)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(L10n.calendarEventOrigin(event.resolvedTitle))
        .accessibilityLabel(L10n.calendarEventOrigin(event.resolvedTitle))
        .accessibilityValue(detailLines.joined(separator: ", "))
        .onChange(of: dynamicTypeSize, initial: true) { _, _ in
            updateAttributedDescription()
        }
        .onChange(of: event.description) { _, _ in
            updateAttributedDescription()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CalendarEventPopoverContent(
                title: event.resolvedTitle,
                dateText: dateText,
                attributedDescription: attributedDescription
            )
        }
    }

    private func togglePresentation() {
        isPresented.toggle()
    }

    private func updateAttributedDescription() {
        attributedDescription = event.description.nilIfBlank.map {
            CalendarEventDescriptionFormatter.attributedString(from: $0)
        }
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
