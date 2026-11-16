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
        alignWindowControls(in: window)
    }

    private static func alignWindowControls(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let closeButton = window.standardWindowButton(.closeButton),
              let titlebar = closeButton.superview,
              let container = titlebar.superview
        else { return }

        // Expand the native controls' host without opting into toolbar window chrome.
        let height = DahliaDesign.windowHeaderHeight
        container.frame.origin.y += container.frame.height - height
        container.frame.size.height = height
        titlebar.frame.size.height = height
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(
                x: button.frame.minX,
                y: (height - button.frame.height) / 2
            ))
        }
    }

    @MainActor
    final class AttachmentView: NSView {
        private var isAligningControls = false
        private var alignmentTask: Task<Void, Never>?
        private var controlFrameObservers: [NSObjectProtocol] = []

        isolated deinit {
            alignmentTask?.cancel()
            for observer in controlFrameObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        override func layout() {
            super.layout()
            alignWindowControls()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            alignmentTask?.cancel()
            alignmentTask = nil
            for observer in controlFrameObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            controlFrameObservers.removeAll()
            if let window {
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    guard let button = window.standardWindowButton(type) else { continue }
                    button.postsFrameChangedNotifications = true
                    controlFrameObservers.append(NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification,
                        object: button,
                        queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.scheduleWindowControlsAlignment()
                        }
                    })
                }
            }
            configureWindow()
        }

        private func scheduleWindowControlsAlignment() {
            guard !isAligningControls, alignmentTask == nil else { return }
            alignmentTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.alignWindowControls()
                self?.alignmentTask = nil
            }
        }

        private func alignWindowControls() {
            guard !isAligningControls, let window else { return }
            isAligningControls = true
            defer { isAligningControls = false }
            DahliaSimpleWindowStyle.alignWindowControls(in: window)
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
