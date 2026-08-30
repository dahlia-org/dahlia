import Foundation

@MainActor
final class MeetingCalendarPopupScheduler {
    private var task: Task<Void, Never>?
    private var state = MeetingCalendarPopupScheduleState()

    func replace(
        with schedule: [(event: CalendarEvent, notificationDate: Date)],
        identifierForEvent: (CalendarEvent) -> String,
        onPresent: @escaping (CalendarEvent, String) -> Void
    ) {
        task?.cancel()
        let entries = schedule.map { entry in
            (
                identifier: identifierForEvent(entry.event),
                event: entry.event,
                notificationDate: entry.notificationDate
            )
        }
        let generation = state.replace(with: Set(entries.map(\.identifier)))

        task = Task { [weak self] in
            for entry in entries {
                let delay = entry.notificationDate.timeIntervalSinceNow
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                }

                guard let self,
                      !Task.isCancelled,
                      entry.event.startDate > .now,
                      state.claim(entry.identifier, generation: generation)
                else { continue }
                onPresent(entry.event, entry.identifier)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state.cancel()
    }
}
