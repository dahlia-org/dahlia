enum CodexChatDeliveryMode: String, CaseIterable, Sendable {
    case steer
    case queue

    var title: String {
        switch self {
        case .steer: L10n.chatSteer
        case .queue: L10n.chatQueue
        }
    }

    var symbol: String {
        switch self {
        case .steer: "arrow.up"
        case .queue: "text.badge.plus"
        }
    }

    func resolved(commandPressed: Bool) -> Self { commandPressed ? opposite : self }

    var opposite: Self { self == .steer ? .queue : .steer }
}
