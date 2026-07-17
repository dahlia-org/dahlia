@MainActor
protocol LiveSubtitlePresenting: AnyObject {
    func update(payload: LiveSubtitleOverlayPayload?)
    func hide()
}
