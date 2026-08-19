#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaWindowHeaderHelpControllerTests {
        @Test
        func storesContainerOverlayPresentation() {
            let controller = DahliaWindowHeaderHelpController(timeline: DahliaWindowHeaderHelpTimeline())
            let id = UUID.v7()
            let buttonFrame = CGRect(x: 100, y: 80, width: 28, height: 28)

            controller.hoverBegan(
                for: id,
                label: "Quick Recording",
                shortcut: nil,
                buttonFrame: buttonFrame
            )

            #expect(controller.helpLabel == "Quick Recording")
            #expect(controller.helpShortcut == nil)
            #expect(controller.helpButtonFrame == buttonFrame)
        }

        @Test
        func waitsSevenTenthsOfASecondBeforeInitialPresentation() async {
            let sleeper = HeaderHelpTestSleeper()
            let controller = DahliaWindowHeaderHelpController(
                sleep: sleeper.sleep,
                timeline: DahliaWindowHeaderHelpTimeline()
            )
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
            let controller = DahliaWindowHeaderHelpController(
                now: clock.now,
                sleep: sleeper.sleep,
                timeline: DahliaWindowHeaderHelpTimeline()
            )
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
        func sharesImmediateSwitchWindowAcrossControllersUntilItExpires() async {
            let clock = HeaderHelpTestClock()
            let firstSleeper = HeaderHelpTestSleeper()
            let secondSleeper = HeaderHelpTestSleeper()
            let timeline = DahliaWindowHeaderHelpTimeline()
            let firstController = DahliaWindowHeaderHelpController(
                now: clock.now,
                sleep: firstSleeper.sleep,
                timeline: timeline
            )
            let secondController = DahliaWindowHeaderHelpController(
                now: clock.now,
                sleep: secondSleeper.sleep,
                timeline: timeline
            )
            let firstID = UUID.v7()
            let secondID = UUID.v7()

            firstController.hoverBegan(for: firstID)
            #expect(await pollUntil { firstSleeper.requestedDuration != nil })
            firstSleeper.resume()
            #expect(await pollUntil { firstController.visibleHelpID == firstID })

            firstController.hoverEnded(for: firstID)
            secondController.hoverBegan(for: secondID)

            #expect(secondController.visibleHelpID == secondID)
            #expect(secondSleeper.requestedDuration == nil)

            secondController.hoverEnded(for: secondID)
            clock.advance(by: .milliseconds(701))
            secondController.hoverBegan(for: UUID.v7())

            #expect(secondController.visibleHelpID == nil)
            #expect(await pollUntil { secondSleeper.requestedDuration == .milliseconds(700) })
            secondController.dismissAll()
            secondSleeper.resume()
        }

        @Test
        func switchesImmediatelyWhenNextControllerEntersBeforePreviousControllerExits() async {
            let firstSleeper = HeaderHelpTestSleeper()
            let secondSleeper = HeaderHelpTestSleeper()
            let timeline = DahliaWindowHeaderHelpTimeline()
            let firstController = DahliaWindowHeaderHelpController(
                sleep: firstSleeper.sleep,
                timeline: timeline
            )
            let secondController = DahliaWindowHeaderHelpController(
                sleep: secondSleeper.sleep,
                timeline: timeline
            )
            let firstID = UUID.v7()
            let secondID = UUID.v7()

            firstController.hoverBegan(for: firstID)
            #expect(await pollUntil { firstSleeper.requestedDuration != nil })
            firstSleeper.resume()
            #expect(await pollUntil { firstController.visibleHelpID == firstID })

            secondController.hoverBegan(for: secondID)
            firstController.hoverEnded(for: firstID)

            #expect(secondController.visibleHelpID == secondID)
            #expect(secondSleeper.requestedDuration == nil)
        }

        @Test
        func cancelsPendingPresentationWhenHoverEnds() async {
            let sleeper = HeaderHelpTestSleeper()
            let controller = DahliaWindowHeaderHelpController(
                sleep: sleeper.sleep,
                timeline: DahliaWindowHeaderHelpTimeline()
            )
            let id = UUID.v7()

            controller.hoverBegan(for: id)
            #expect(await pollUntil { sleeper.requestedDuration != nil })
            controller.hoverEnded(for: id)
            sleeper.resume()
            await Task.yield()

            #expect(controller.visibleHelpID == nil)
        }

        @Test
        func dismissAllCancelsPendingPresentation() async {
            let sleeper = HeaderHelpTestSleeper()
            let controller = DahliaWindowHeaderHelpController(
                sleep: sleeper.sleep,
                timeline: DahliaWindowHeaderHelpTimeline()
            )
            let id = UUID.v7()

            controller.hoverBegan(for: id)
            #expect(await pollUntil { sleeper.requestedDuration != nil })
            controller.dismissAll()
            sleeper.resume()
            #expect(await pollUntil { sleeper.didReturnFromSleep })

            #expect(controller.visibleHelpID == nil)
        }

        @Test
        func dismissAllClearsVisiblePresentation() async {
            let controller = DahliaWindowHeaderHelpController(
                displayDelay: .zero,
                timeline: DahliaWindowHeaderHelpTimeline()
            )
            let id = UUID.v7()

            controller.hoverBegan(for: id)
            #expect(await pollUntil { controller.visibleHelpID == id })
            controller.dismissAll()

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
        private(set) var didReturnFromSleep = false

        func sleep(for duration: Duration) async {
            requestedDuration = duration
            await withCheckedContinuation { continuation = $0 }
            didReturnFromSleep = true
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
#endif
