import Combine
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct ScreenshotStoreTests {
        @Test
        func upsertMaintainsOrderAndRejectsAnotherMeeting() throws {
            let store = ScreenshotStore()
            let meetingID = UUID.v7()
            let later = makeScreenshot(meetingID: meetingID, capturedAt: .now)
            let earlier = makeScreenshot(
                meetingID: meetingID,
                capturedAt: later.capturedAt.addingTimeInterval(-10)
            )
            let otherMeeting = makeScreenshot(meetingID: UUID.v7(), capturedAt: .now)

            store.replace(meetingID: meetingID, records: [])
            let replacementRevision = store.contentRevision
            store.upsert(later)
            store.upsert(earlier)
            store.upsert(otherMeeting)

            #expect(store.records.map(\.id) == [earlier.id, later.id])
            #expect(store.contentRevision == replacementRevision + 2)
            #expect(store.contentRevision(for: later.id) == replacementRevision + 1)
            #expect(store.contentRevision(for: earlier.id) == replacementRevision + 2)
            #expect(store.contentRevision(for: otherMeeting.id) == nil)

            var updated = later
            updated.mimeType = "image/jpeg"
            store.upsert(updated)
            #expect(try #require(store.records.last).mimeType == "image/jpeg")
            #expect(store.contentRevision == replacementRevision + 3)
            #expect(store.contentRevision(for: later.id) == replacementRevision + 3)
        }

        @Test
        func removeAndClearStayScopedToTheDisplayedMeeting() {
            let store = ScreenshotStore()
            let meetingID = UUID.v7()
            let first = makeScreenshot(meetingID: meetingID, capturedAt: .now)
            let second = makeScreenshot(
                meetingID: meetingID,
                capturedAt: first.capturedAt.addingTimeInterval(1)
            )
            store.replace(meetingID: meetingID, records: [first, second])

            store.remove(ids: [first.id], meetingID: UUID.v7())
            #expect(store.records.map(\.id) == [first.id, second.id])

            store.remove(ids: [first.id], meetingID: meetingID)
            #expect(store.records.map(\.id) == [second.id])
            #expect(store.contentRevision(for: first.id) == nil)
            #expect(store.contentRevision(for: second.id) != nil)

            store.clear()
            #expect(store.meetingID == nil)
            #expect(store.records.isEmpty)
            #expect(store.contentRevision(for: second.id) == nil)
        }

        @Test
        func screenshotProjectionDoesNotPublishThroughCaptionViewModel() {
            let viewModel = CaptionViewModel(
                audioHardwareQueryService: AudioHardwareQueryService(
                    availableInputDevicesProvider: { [] },
                    defaultInputDeviceIDProvider: { nil }
                )
            )
            var captionViewModelChangeCount = 0
            var screenshotStoreChangeCount = 0
            let captionViewModelCancellable = viewModel.objectWillChange.sink {
                captionViewModelChangeCount += 1
            }
            let screenshotStoreCancellable = viewModel.screenshotStore.objectWillChange.sink {
                screenshotStoreChangeCount += 1
            }

            let meetingID = UUID.v7()
            viewModel.screenshotStore.replace(meetingID: meetingID, records: [
                makeScreenshot(meetingID: meetingID, capturedAt: .now),
            ])

            #expect(captionViewModelChangeCount == 0)
            #expect(screenshotStoreChangeCount == 1)
            withExtendedLifetime((captionViewModelCancellable, screenshotStoreCancellable)) {}
        }

        private func makeScreenshot(meetingID: UUID, capturedAt: Date) -> MeetingScreenshotRecord {
            MeetingScreenshotRecord(
                id: .v7(),
                meetingId: meetingID,
                capturedAt: capturedAt,
                imageData: Data([0]),
                mimeType: "image/png"
            )
        }
    }
#endif
