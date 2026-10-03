import AppKit

@MainActor
final class SplitViewAttachmentTrackingView: NSView {
    var onAttachmentChange: ((SplitViewAttachmentTrackingView) -> Void)?

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
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
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
