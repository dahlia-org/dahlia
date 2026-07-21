import AppKit
import SwiftUI

/// `View` 以外の文脈からメインウィンドウを開くための小さなブリッジ。
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()

    private var openWindowAction: OpenWindowAction?

    private init() {}

    func register(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    func openMainWindow() {
        if let openWindowAction {
            openWindowAction(id: WindowID.main)
        } else {
            focusExistingMainWindow()
        }

        guard let application = NSApp else { return }
        application.activate(ignoringOtherApps: true)
        focusExistingMainWindow()
    }

    func focusExistingMainWindow() {
        guard let application = NSApp else { return }
        // Settings や Project Manager を誤って前面化しないよう、メインウィンドウの
        // 識別子を持つものだけを対象にする（SwiftUI は "main-AppWindow-1" 形式を付与する）。
        let targetWindow = application.windows.first { window in
            guard let identifier = window.identifier?.rawValue else { return false }
            return identifier == WindowID.main || identifier.hasPrefix("\(WindowID.main)-")
        }

        targetWindow?.orderFrontRegardless()
        targetWindow?.makeKeyAndOrderFront(nil)
    }
}
