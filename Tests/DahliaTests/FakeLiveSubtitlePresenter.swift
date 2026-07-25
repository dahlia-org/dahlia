@testable import Dahlia

@MainActor
final class FakeLiveSubtitlePresenter: LiveSubtitlePresenting {
    private(set) var lastPayload: LiveSubtitleOverlayPayload?
    private(set) var hideCount = 0
    private(set) var updateCount = 0

    func update(payload: LiveSubtitleOverlayPayload?) {
        updateCount += 1
        lastPayload = payload
    }

    func hide() {
        hideCount += 1
        lastPayload = nil
    }
}
