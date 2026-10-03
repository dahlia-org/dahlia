import SwiftUI

struct SidebarMaterialBackground: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        configureWindowWhenAttached(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        configureWindowWhenAttached(to: view)
    }

    private func configureWindowWhenAttached(to view: NSVisualEffectView) {
        Task { @MainActor [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
