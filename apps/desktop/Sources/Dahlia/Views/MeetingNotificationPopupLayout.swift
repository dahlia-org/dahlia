import AppKit

enum MeetingNotificationPopupLayout {
    static let width: CGFloat = 640
    static let minimumHeight: CGFloat = 340
    static let cornerRadius: CGFloat = 28

    static func origin(panelSize: NSSize, visibleScreenFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleScreenFrame.midX - panelSize.width / 2,
            y: visibleScreenFrame.midY - panelSize.height / 2
        )
    }
}
