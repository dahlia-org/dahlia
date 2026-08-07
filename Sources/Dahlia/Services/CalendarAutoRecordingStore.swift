import Combine
import Foundation

/// カレンダー予定ごとの一回限りの自動録音予約をローカル設定に保存する。
@MainActor
final class CalendarAutoRecordingStore: ObservableObject {
    static let shared = CalendarAutoRecordingStore()
    static let selectionsUserDefaultsKey = "calendarAutoRecordingSelections"

    @Published private(set) var selections: [CalendarAutoRecordingSelection]

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        selections = Self.loadSelections(from: userDefaults)
    }

    var hasSelections: Bool {
        !selections.isEmpty
    }

    func isEnabled(for event: CalendarEvent) -> Bool {
        let eventID = CalendarAutoRecordingEventID(event: event)
        return selections.contains { $0.eventID == eventID }
    }

    func setEnabled(_ isEnabled: Bool, for event: CalendarEvent) {
        guard !event.isAllDay else { return }
        let eventID = CalendarAutoRecordingEventID(event: event)
        var updated = selections.filter { $0.eventID != eventID }
        if isEnabled {
            updated.append(CalendarAutoRecordingSelection(event: event))
        }
        replaceSelections(updated)
    }

    func synchronize(with events: [CalendarEvent], now: Date) {
        let eventsByID = Dictionary(
            events.map { (CalendarAutoRecordingEventID(event: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let updated = selections.compactMap { selection -> CalendarAutoRecordingSelection? in
            if let event = eventsByID[selection.eventID] {
                guard event.endDate > now, !event.isAllDay else { return nil }
                return CalendarAutoRecordingSelection(event: event)
            }
            return selection.endDate > now ? selection : nil
        }
        replaceSelections(updated)
    }

    func consume(_ eventIDs: Set<CalendarAutoRecordingEventID>) {
        replaceSelections(selections.filter { !eventIDs.contains($0.eventID) })
    }

    private func replaceSelections(_ updated: [CalendarAutoRecordingSelection]) {
        let sorted = updated.sorted { $0.eventID.sortKey < $1.eventID.sortKey }
        guard sorted != selections else { return }
        selections = sorted
        Self.persist(sorted, to: userDefaults)
    }

    private static func loadSelections(from userDefaults: UserDefaults) -> [CalendarAutoRecordingSelection] {
        guard let data = userDefaults.data(forKey: selectionsUserDefaultsKey),
              let decoded = try? JSONDecoder().decode([CalendarAutoRecordingSelection].self, from: data)
        else { return [] }
        return decoded.sorted { $0.eventID.sortKey < $1.eventID.sortKey }
    }

    private static func persist(_ selections: [CalendarAutoRecordingSelection], to userDefaults: UserDefaults) {
        guard !selections.isEmpty else {
            userDefaults.removeObject(forKey: selectionsUserDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(selections) else { return }
        userDefaults.set(data, forKey: selectionsUserDefaultsKey)
    }
}
