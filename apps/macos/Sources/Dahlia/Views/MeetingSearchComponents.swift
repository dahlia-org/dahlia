import SwiftUI

struct MeetingSearchTokenLabel: View {
    let token: MeetingSearchToken
    let projects: [FlatProjectRow]
    let tags: [TagRecord]

    var body: some View {
        switch token.value {
        case let .project(id, storedName):
            let project = projects.first(where: { $0.id == id })
            let name = project?.name ?? storedName
            let displayName = project == nil ? L10n.unknownProject : name
            Text(displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(project == nil ? L10n.unknownProjectFilterHelp : L10n.projectFilterHelp(name))
                .accessibilityLabel(
                    project == nil
                        ? L10n.unknownProjectFilterAccessibilityLabel
                        : L10n.projectFilterAccessibilityLabel(name)
                )
        case let .tag(id, storedName, _):
            let tag = tags.first(where: { $0.id == id })
            let name = tag?.name ?? storedName
            let displayName = tag == nil ? L10n.unknownTag : name
            Text(displayName)
                .lineLimit(1)
                .help(tag == nil ? L10n.unknownTagFilterHelp : L10n.tagFilterHelp(name))
                .accessibilityLabel(
                    tag == nil
                        ? L10n.unknownTagFilterAccessibilityLabel
                        : L10n.tagFilterAccessibilityLabel(name)
                )
        case let .dateRange(startDate, endDate):
            let label = dateRangeLabel(startDate: startDate, endDate: endDate)
            Text(label)
                .lineLimit(1)
                .help(L10n.periodFilter)
                .accessibilityLabel(L10n.periodFilterAccessibilityLabel(label))
        }
    }

    private func dateRangeLabel(startDate: Date?, endDate: Date?) -> String {
        let calendar = Calendar.current
        switch (startDate, endDate) {
        case let (.some(start), .some(end)):
            let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            return L10n.dateRange(
                shortDateLabel(start),
                shortDateLabel(inclusiveEnd)
            )
        case let (.some(start), .none):
            return L10n.dateOnOrAfter(shortDateLabel(start))
        case let (.none, .some(end)):
            return L10n.dateBefore(shortDateLabel(end))
        case (.none, .none):
            return L10n.period
        }
    }

    private func shortDateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct MeetingSearchDateRangeView: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    let onCancel: () -> Void
    let onApply: () -> Void

    private var isValid: Bool {
        Calendar.current.startOfDay(for: startDate) <= Calendar.current.startOfDay(for: endDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.customDateRange)
                .font(.headline)

            DatePicker(L10n.startDate, selection: $startDate, displayedComponents: .date)
            DatePicker(L10n.endDate, selection: $endDate, displayedComponents: .date)

            if !isValid {
                Label(L10n.invalidDateRange, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.cancel, action: onCancel)
                Button(L10n.apply, action: onApply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
