struct MeetingNotificationPopupQueue {
    private(set) var current: MeetingNotificationPopup?
    private(set) var pending: [MeetingNotificationPopup] = []

    mutating func enqueue(_ popup: MeetingNotificationPopup) -> Bool {
        if current?.id == popup.id {
            current = popup
            return true
        }
        if let index = pending.firstIndex(where: { $0.id == popup.id }) {
            pending[index] = popup
            return false
        }
        guard current != nil else {
            current = popup
            return true
        }
        pending.append(popup)
        return false
    }

    @discardableResult
    mutating func advance() -> MeetingNotificationPopup? {
        current = pending.isEmpty ? nil : pending.removeFirst()
        return current
    }

    mutating func removeCalendarNotifications() -> Bool {
        pending.removeAll(where: \.isCalendarNotification)
        guard current?.isCalendarNotification == true else { return false }
        advance()
        return true
    }

    mutating func retainCalendarNotifications(withIdentifiers identifiers: Set<String>) -> Bool {
        pending.removeAll { $0.isCalendarNotification && !identifiers.contains($0.id) }
        guard let current,
              current.isCalendarNotification,
              !identifiers.contains(current.id)
        else { return false }
        advance()
        return true
    }

    mutating func removeMicrophoneNotifications() -> Bool {
        pending.removeAll { !$0.isCalendarNotification }
        guard current?.isCalendarNotification == false else { return false }
        advance()
        return true
    }

    mutating func removeAll() {
        current = nil
        pending.removeAll()
    }
}
