import AppKit

@MainActor
final class SplitViewAttachmentTrackingView: NSView {
    var onAttachmentChange: ((SplitViewAttachmentTrackingView) -> Void)?
    var attachmentDelay = Duration.zero

    private var attachmentTask: Task<Void, Never>?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleAttachmentUpdate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAttachmentUpdate()
    }

    func scheduleAttachmentUpdate() {
        attachmentTask?.cancel()
        attachmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delay = attachmentDelay
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                attachmentDelay = .zero
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            onAttachmentChange?(self)
        }
    }

    func invalidate() {
        attachmentTask?.cancel()
        attachmentTask = nil
        onAttachmentChange = nil
    }

    deinit {
        attachmentTask?.cancel()
    }
}
