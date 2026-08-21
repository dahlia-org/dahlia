enum MeetingNotificationPresentation: String, CaseIterable, Identifiable {
    case prominentPopup
    case systemNotification

    nonisolated static let userDefaultsKey = "meetingNotificationPresentation"
    nonisolated static let defaultValue: Self = .systemNotification

    var id: String { rawValue }

    init(storedRawValue: String) {
        self = Self(rawValue: storedRawValue) ?? .defaultValue
    }

    var displayName: String {
        switch self {
        case .prominentPopup: L10n.prominentPopup
        case .systemNotification: L10n.macOSNotification
        }
    }
}
