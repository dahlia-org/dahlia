import AppKit
import SwiftUI

struct DahliaSimpleWindowStyle: NSViewRepresentable {
    func makeNSView(context _: Context) -> AttachmentView {
        AttachmentView()
    }

    func updateNSView(_ nsView: AttachmentView, context _: Context) {
        nsView.configureWindow()
    }

    static func apply(to window: NSWindow) {
        window.toolbar = nil
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }

    @MainActor
    final class AttachmentView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            DahliaSimpleWindowStyle.apply(to: window)
        }
    }
}

extension View {
    func dahliaSimpleWindowStyle() -> some View {
        ignoresSafeArea(.container, edges: .top)
            .background {
                DahliaSimpleWindowStyle()
            }
            .coordinateSpace(name: DahliaWindowHeaderHelpLayout.windowCoordinateSpaceName)
    }
}
