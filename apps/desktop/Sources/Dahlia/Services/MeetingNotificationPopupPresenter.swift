import AppKit
import SwiftUI

@MainActor
final class MeetingNotificationPopupPresenter {
    private var queue = MeetingNotificationPopupQueue()
    private var panel: NSPanel?
    private var actionHandler: ((MeetingNotificationPopup, MeetingNotificationPopup.Action) -> Void)?

    func present(
        _ popup: MeetingNotificationPopup,
        onAction: @escaping (MeetingNotificationPopup, MeetingNotificationPopup.Action) -> Void
    ) {
        actionHandler = onAction
        guard queue.enqueue(popup) else { return }
        showCurrent()
    }

    func removeCalendarNotifications() {
        guard queue.removeCalendarNotifications() else { return }
        showCurrent()
    }

    func retainCalendarNotifications(withIdentifiers identifiers: Set<String>) {
        guard queue.retainCalendarNotifications(withIdentifiers: identifiers) else { return }
        showCurrent()
    }

    func removeMicrophoneNotifications() {
        guard queue.removeMicrophoneNotifications() else { return }
        showCurrent()
    }

    func removeAll() {
        queue.removeAll()
        actionHandler = nil
        closePanel()
    }

    private func showCurrent() {
        closePanel()
        guard let popup = queue.current else {
            actionHandler = nil
            return
        }

        let hostingView = NSHostingView(rootView: MeetingNotificationPopupView(
            popup: popup,
            onAction: { [weak self] action in
                self?.perform(action)
            }
        ).dahliaAppearance())
        hostingView.layoutSubtreeIfNeeded()
        hostingView.setFrameSize(hostingView.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        if let visibleFrame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(MeetingNotificationPopupLayout.origin(
                panelSize: panel.frame.size,
                visibleScreenFrame: visibleFrame
            ))
        }

        self.panel = panel
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(L10n.meetingNotification)。\(popup.title)。\(popup.body)",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func perform(_ action: MeetingNotificationPopup.Action) {
        guard let popup = queue.current else { return }
        closePanel()
        actionHandler?(popup, action)
        queue.advance()
        showCurrent()
    }

    private func closePanel() {
        panel?.close()
        panel = nil
    }
}
