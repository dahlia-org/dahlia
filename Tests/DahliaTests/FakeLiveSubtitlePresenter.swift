@testable import Dahlia

@MainActor
final class FakeLiveSubtitlePresenter: LiveSubtitlePresenting {
    private(set) var lastPayload: LiveSubtitleOverlayPayload?
    private(set) var hideCount = 0

    func update(payload: LiveSubtitleOverlayPayload?) {
        lastPayload = payload
    }

    func hide() {
        hideCount += 1
        lastPayload = nil
    }
}
