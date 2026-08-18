#if canImport(Testing)
import Foundation
import Testing
@testable import Dahlia

@MainActor
struct DahliaWindowHeaderHelpControllerTests {
    @Test
    func storesContainerOverlayPresentation() {
        let controller = DahliaWindowHeaderHelpController()
        let id = UUID.v7()
        let buttonFrame = CGRect(x: 100, y: 80, width: 28, height: 28)

        controller.hoverBegan(
            for: id,
            label: "Quick Recording",
            shortcut: nil,
            buttonFrame: buttonFrame,
            presentsInContainerOverlay: true
        )

        #expect(controller.helpLabel == "Quick Recording")
        #expect(controller.helpShortcut == nil)
        #expect(controller.helpButtonFrame == buttonFrame)
        #expect(controller.presentsHelpInContainerOverlay)
    }

    @Test
    func waitsSevenTenthsOfASecondBeforeInitialPresentation() async {
        let sleeper = HeaderHelpTestSleeper()
        let controller = DahliaWindowHeaderHelpController(sleep: sleeper.sleep)
        let id = UUID.v7()

        controller.hoverBegan(for: id)

        #expect(controller.visibleHelpID == nil)
        #expect(await pollUntil { sleeper.requestedDuration != nil })
        #expect(sleeper.requestedDuration == .milliseconds(700))

        sleeper.resume()
        #expect(await pollUntil { controller.visibleHelpID == id })
    }

    @Test
    func startsImmediateSwitchWindowWhenPresentedHelpIsDismissed() async {
        let clock = HeaderHelpTestClock()
        let sleeper = HeaderHelpTestSleeper()
        let controller = DahliaWindowHeaderHelpController(now: clock.now, sleep: sleeper.sleep)
        let sidebarID = UUID.v7()
        let searchID = UUID.v7()

        controller.hoverBegan(for: sidebarID)
        #expect(await pollUntil { sleeper.requestedDuration != nil })
        sleeper.resume()
        #expect(await pollUntil { controller.visibleHelpID == sidebarID })

        clock.advance(by: .seconds(10))
        controller.hoverEnded(for: sidebarID)
        controller.hoverBegan(for: searchID)

        #expect(controller.visibleHelpID == searchID)
    }

    @Test
    func cancelsPendingPresentationWhenHoverEnds() async {
        let sleeper = HeaderHelpTestSleeper()
        let controller = DahliaWindowHeaderHelpController(sleep: sleeper.sleep)
        let id = UUID.v7()

        controller.hoverBegan(for: id)
        #expect(await pollUntil { sleeper.requestedDuration != nil })
        controller.hoverEnded(for: id)
        sleeper.resume()
        await Task.yield()

        #expect(controller.visibleHelpID == nil)
    }
}

@MainActor
private final class HeaderHelpTestClock {
    private var instant = ContinuousClock.now

    func now() -> ContinuousClock.Instant {
        instant
    }

    func advance(by duration: Duration) {
        instant += duration
    }
}

@MainActor
private final class HeaderHelpTestSleeper {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requestedDuration: Duration?

    func sleep(for duration: Duration) async {
        requestedDuration = duration
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
#endif
