import AppKit
import SwiftUI

@MainActor
final class MainSidebarHelpMenuCoordinator: NSObject {
    weak var button: NSButton?

    private var onOpenMCP: () -> Void
    private let navigation = MainSidebarAccountMenuNavigationState()
    private var panel: NSPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init(onOpenMCP: @escaping () -> Void) {
        self.onOpenMCP = onOpenMCP
    }

    func update(onOpenMCP: @escaping () -> Void) {
        self.onOpenMCP = onOpenMCP
    }

    @objc
    func toggleMenu() {
        if panel == nil {
            presentMenu()
        } else {
            dismissMenu()
        }
    }

    func dismissMenu() {
        stopMonitoring()
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.close()
        self.panel = nil
        navigation.reset()
    }

    private func presentMenu() {
        guard let button else { return }
        navigation.reset()
        let content = MainSidebarAccountMenuPanel(width: MainSidebarAccountMenuLayout.menuWidth) {
            MainSidebarHelpMenuView(
                navigation: navigation,
                onOpenMCP: { [weak self] in self?.openMCP() }
            )
        }
        let hostingView = NSHostingView(rootView: content.fixedSize().dahliaAppearance())
        hostingView.frame.size = hostingView.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        position(panel, relativeTo: button)
        if let parentWindow = button.window {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        self.panel = panel
        startMonitoring()
    }

    private func position(_ panel: NSPanel, relativeTo button: NSButton) {
        guard let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screens = NSScreen.screens
        let screenFrame = MainSidebarAccountMenuLayout.screenIndex(
            containing: buttonFrame,
            screenFrames: screens.map(\.frame)
        ).map { screens[$0].visibleFrame } ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(MainSidebarAccountMenuLayout.mainMenuOrigin(
            panelSize: panel.frame.size,
            buttonFrame: buttonFrame,
            screenFrame: screenFrame
        ))
    }

    private func openMCP() {
        dismissMenu()
        onOpenMCP()
    }

    private func startMonitoring() {
        let localEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: localEvents) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                return handleKeyDown(event)
            }
            let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            guard !contains(location) else { return event }
            dismissMenu()
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissMenu() }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if MainSidebarAccountMenuCoordinator.shouldPassThroughKeyEvent(modifierFlags: event.modifierFlags) {
            dismissMenu()
            return event
        }
        switch event.keyCode {
        case 53:
            dismissMenu()
        case 36, 49, 76:
            if navigation.rootSelection == 0 { openMCP() }
        case 48, 125, 126:
            navigation.rootSelection = 0
            announce(L10n.mcpSettings)
        default:
            break
        }
        return nil
    }

    private func contains(_ screenPoint: NSPoint) -> Bool {
        if panel?.frame.contains(screenPoint) == true { return true }
        guard let button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(screenPoint)
    }

    @objc
    private func applicationDidResignActive() {
        dismissMenu()
    }

    private func stopMonitoring() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func announce(_ message: String) {
        guard let panel else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
