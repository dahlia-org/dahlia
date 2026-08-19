import SwiftUI

struct ProjectDetailCalendarView: View {
    let displayedMonth: Date
    let items: [MeetingSidebarItem]
    let appearanceForProject: (UUID) -> ProjectAppearance
    let isLoading: Bool
    let isLimited: Bool
    let error: String?
    let onOpenMeeting: (UUID) -> Void
    let onRetry: () -> Void

    @State private var selectedDay: ProjectCalendarDay?
    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 12) {
            weekdayHeader

            if let error, items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.meetingListLoadFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(L10n.retry, action: onRetry)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading, items.isEmpty {
                ProgressView(L10n.loadingMeetings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                calendarGrid
            }

            if isLimited {
                Text(L10n.projectCalendarLimitReached)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .popover(item: $selectedDay) { day in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(day.meetings) { item in
                        Button(action: { onOpenMeeting(item.meetingId) }) {
                            ProjectDetailMeetingRow(item: item)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .frame(width: 360, height: min(CGFloat(day.meetings.count) * 58 + 20, 420))
            .padding(.vertical, 8)
        }
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(rotatedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(ProjectCalendarMonth.days(containing: displayedMonth, meetings: items, calendar: calendar)) { day in
                dayCell(day)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private func dayCell(_ day: ProjectCalendarDay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.date, format: .dateTime.day())
                .font(.caption)
                .foregroundStyle(day.isInMonth ? .primary : .tertiary)
                .accessibilityLabel(day.date.formatted(date: .long, time: .omitted))

            ForEach(day.visibleMeetings) { item in
                ProjectDetailCalendarMeetingButton(
                    item: item,
                    projectAppearance: item.projectId.map(appearanceForProject),
                    onOpen: { onOpenMeeting(item.meetingId) }
                )
            }

            if day.hiddenMeetingCount > 0 {
                Button(L10n.otherMeetings(day.hiddenMeetingCount)) {
                    selectedDay = day
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(day.isInMonth ? Color.clear : Color.secondary.opacity(0.04))
        .overlay(alignment: .topTrailing) {
            Rectangle().fill(.separator).frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }

    private var rotatedWeekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }
}
