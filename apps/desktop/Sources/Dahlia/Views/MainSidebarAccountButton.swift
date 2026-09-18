import AppKit

final class MainSidebarAccountButton: NSButton {
    private let symbolImageView = NSImageView()
    private var isAnimatingIcon = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSymbolImageView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSymbolImageView()
    }

    private func configureSymbolImageView() {
        symbolImageView.imageScaling = .scaleProportionallyDown
        symbolImageView.setAccessibilityElement(false)
        addSubview(symbolImageView)
    }

    func setIcon(_ icon: NSImage?, animated: Bool) {
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate, let icon else {
            if isAnimatingIcon {
                symbolImageView.removeAllSymbolEffects(options: .default, animated: false)
                isAnimatingIcon = false
            }
            symbolImageView.isHidden = true
            image = icon
            return
        }

        image = NSImage(size: icon.size)
        symbolImageView.image = icon
        symbolImageView.isHidden = false
        if !isAnimatingIcon {
            symbolImageView.addSymbolEffect(.rotate, options: .repeat(.continuous))
            isAnimatingIcon = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        symbolImageView.frame = cell?.imageRect(forBounds: bounds) ?? .zero
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}
