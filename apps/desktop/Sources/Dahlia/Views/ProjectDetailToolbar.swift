import SwiftUI

struct ProjectDetailToolbar: View {
    @Binding var displayedMonth: Date
    let displayMode: ProjectDetailDisplayMode
    let onChangeDisplayMode: (ProjectDetailDisplayMode) -> Void

    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 6) {
            ProjectDetailDisplayModePicker(
                displayMode: displayMode,
                onChange: onChangeDisplayMode
            )

            Spacer()

            if displayMode == .calendar {
                Text(displayedMonth, format: .dateTime.year().month(.wide))
                    .font(.title2)
                    .accessibilityAddTraits(.isHeader)

                Button(L10n.previousMonth, systemImage: "arrow.backward") { moveMonth(by: -1) }
                    .labelStyle(.iconOnly)
                    .projectCalendarNavigationControl()
                Button(L10n.today) { displayedMonth = .now }
                    .projectCalendarNavigationControl()
                Button(L10n.nextMonth, systemImage: "arrow.forward") { moveMonth(by: 1) }
                    .labelStyle(.iconOnly)
                    .projectCalendarNavigationControl()
            }
        }
    }

    private func moveMonth(by value: Int) {
        displayedMonth = ProjectCalendarMonth.date(byAddingMonths: value, to: displayedMonth, calendar: calendar)
    }
}
