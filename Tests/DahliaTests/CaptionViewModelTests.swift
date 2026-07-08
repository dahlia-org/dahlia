import CoreAudio
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CaptionViewModelTests {
        private let testVaultURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        @Test
        func systemDefaultMicrophoneSelectionResolvesCurrentDefaultDevice() {
            let inputProvider = MutableMicrophoneInputProvider(
                defaultDeviceID: AudioDeviceID(101),
                devices: [
                    MicrophoneDevice(id: 101, name: "Poly Sync 20"),
                    MicrophoneDevice(id: 202, name: "MacBook Pro Mic"),
                ]
            )
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { inputProvider.devices },
                defaultInputDeviceIDProvider: { inputProvider.defaultDeviceID }
            )

            #expect(viewModel.microphoneSelection == MicrophoneSelection.systemDefault)
            #expect(viewModel.selectedMicrophoneID == 101)

            inputProvider.defaultDeviceID = 202

            #expect(viewModel.selectedMicrophoneID == 202)
        }

        @Test
        func missingSelectedMicrophoneFallsBackToSystemDefaultSelection() {
            let inputProvider = MutableMicrophoneInputProvider(
                defaultDeviceID: AudioDeviceID(202),
                devices: [
                    MicrophoneDevice(id: 101, name: "Poly Sync 20"),
                    MicrophoneDevice(id: 202, name: "MacBook Pro Mic"),
                ]
            )
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { inputProvider.devices },
                defaultInputDeviceIDProvider: { inputProvider.defaultDeviceID }
            )

            viewModel.microphoneSelection = .device(101)
            inputProvider.devices = [MicrophoneDevice(id: 202, name: "MacBook Pro Mic")]
            viewModel.refreshAvailableMicrophones()

            #expect(viewModel.microphoneSelection == MicrophoneSelection.systemDefault)
            #expect(viewModel.selectedMicrophoneID == 202)
        }

        @Test
        func unsupportedLocaleFallsBackToPreferredSupportedLanguageVariant() {
            let supportedLocales = [
                Locale(identifier: "en_AU"),
                Locale(identifier: "en_US"),
                Locale(identifier: "ja_JP"),
            ]

            let resolved = CaptionViewModel.resolvedSupportedLocaleIdentifier(
                preferredIdentifier: "en_JP",
                supportedLocales: supportedLocales
            )

            #expect(resolved == "en_US")
        }

        @Test
        func localeIdentifierExtensionsAreStrippedBeforeSupportLookup() {
            let supportedLocales = [
                Locale(identifier: "en_US"),
                Locale(identifier: "ja_JP"),
            ]

            let resolved = CaptionViewModel.resolvedSupportedLocaleIdentifier(
                preferredIdentifier: "ja_JP@calendar=iso8601",
                supportedLocales: supportedLocales
            )

            #expect(resolved == "ja_JP")
        }

        @Test
        func selectingActiveRecordingMeetingKeepsLiveTranscriptStore() throws {
            let viewModel = CaptionViewModel()
            let dbQueue = try DatabaseQueue(path: ":memory:")
            let meetingId = UUID.v7()
            let initialSegment = TranscriptSegment(
                startTime: Date(),
                text: "live transcript",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            viewModel.isListening = true
            viewModel.currentMeetingId = meetingId
            viewModel.currentVaultURL = testVaultURL
            viewModel.store.loadSegments([initialSegment])

            let storeIdentity = ObjectIdentifier(viewModel.store)

            viewModel.loadMeeting(
                meetingId,
                dbQueue: dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: testVaultURL
            )

            #expect(ObjectIdentifier(viewModel.store) == storeIdentity)
            #expect(viewModel.store.segments == [initialSegment])
            #expect(viewModel.recordingMeetingId == meetingId)
        }

        @Test
        func currentMeetingHasTranscriptSegmentsTracksStoreContents() {
            let viewModel = CaptionViewModel()
            let segment = TranscriptSegment(
                startTime: Date(),
                text: "confirmed transcript",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            #expect(!viewModel.currentMeetingHasTranscriptSegments)

            viewModel.store.loadSegments([segment])
            #expect(viewModel.currentMeetingHasTranscriptSegments)

            viewModel.store.clear()
            #expect(!viewModel.currentMeetingHasTranscriptSegments)
        }

        @Test
        func canGenerateSummaryIsDisabledWhileListening() {
            let viewModel = CaptionViewModel()
            let segment = TranscriptSegment(
                startTime: Date(),
                text: "confirmed transcript",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            viewModel.currentMeetingId = UUID.v7()
            viewModel.currentVaultURL = testVaultURL
            viewModel.store.loadSegments([segment])

            #expect(viewModel.canGenerateSummary)

            viewModel.isListening = true

            #expect(!viewModel.canGenerateSummary)
        }

        @Test
        func beginDraftMeetingDoesNotPersistMeetingRecord() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")
            let event = GoogleCalendarEvent(
                id: "primary::event-1",
                calendarID: "primary",
                calendarName: "Primary",
                calendarColorHex: "#4285F4",
                platformId: "event-1",
                title: "Design review",
                description: "Review launch checklist",
                icalUid: "event-1@google.com",
                startDate: Date(timeIntervalSince1970: 1_776_384_000),
                endDate: Date(timeIntervalSince1970: 1_776_387_600),
                isAllDay: false,
                meetingURL: URL(string: "https://meet.google.com/test-link")
            )
            let vaultId = UUID.v7()
            try database.dbQueue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: testVaultURL.path,
                    name: "Test Vault",
                    createdAt: Date(),
                    lastOpenedAt: Date()
                ).insert(db)
            }

            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )

            let counts = try database.dbQueue.read { db in
                try (
                    MeetingRecord.fetchCount(db),
                    CalendarEventRecord.fetchCount(db)
                )
            }

            #expect(viewModel.hasDraftMeeting)
            #expect(viewModel.draftMeetingTitle == "Design review")
            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
        }

        @Test
        func clearCurrentMeetingDiscardsDraftMeeting() {
            let viewModel = CaptionViewModel()
            let event = GoogleCalendarEvent(
                id: "primary::event-1",
                calendarID: "primary",
                calendarName: "Primary",
                calendarColorHex: "#4285F4",
                platformId: "event-1",
                title: "Design review",
                description: "",
                icalUid: "event-1@google.com",
                startDate: Date(timeIntervalSince1970: 1_776_384_000),
                endDate: Date(timeIntervalSince1970: 1_776_387_600),
                isAllDay: false,
                meetingURL: nil
            )

            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: try! DatabaseQueue(path: ":memory:"),
                vaultURL: testVaultURL
            )
            viewModel.clearCurrentMeeting()

            #expect(!viewModel.hasDraftMeeting)
            #expect(viewModel.currentMeetingId == nil)
        }

        @Test
        func materializeDraftMeetingPersistsMeetingAndCalendarEvent() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")
            let vaultId = UUID.v7()
            try database.dbQueue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: testVaultURL.path,
                    name: "Test Vault",
                    createdAt: Date(),
                    lastOpenedAt: Date()
                ).insert(db)
            }
            let previousVault = AppSettings.shared.currentVault
            AppSettings.shared.currentVault = VaultRecord(
                id: vaultId,
                path: testVaultURL.path,
                name: "Test Vault",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            defer { AppSettings.shared.currentVault = previousVault }

            viewModel.beginDraftMeeting(
                from: GoogleCalendarEvent(
                    id: "primary::event-1",
                    calendarID: "primary",
                    calendarName: "Primary",
                    calendarColorHex: "#4285F4",
                    platformId: "event-1",
                    title: "Design review",
                    description: "Review launch checklist",
                    icalUid: "event-1@google.com",
                    startDate: Date(timeIntervalSince1970: 1_776_384_000),
                    endDate: Date(timeIntervalSince1970: 1_776_387_600),
                    isAllDay: false,
                    meetingURL: URL(string: "https://meet.google.com/test-link")
                ),
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )

            let meetingId = try #require(viewModel.materializeDraftMeeting())
            let persisted = try database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
                let calendarEvent = try CalendarEventRecord.filter(Column("meetingId") == meetingId).fetchOne(db)
                return try (
                    #require(meeting),
                    #require(calendarEvent)
                )
            }

            #expect(persisted.0.name == "Design review")
            #expect(persisted.1.platformId == "event-1")
            #expect(persisted.1.meetingUrl == "https://meet.google.com/test-link")
            #expect(!viewModel.hasDraftMeeting)
            #expect(viewModel.currentMeetingId == meetingId)
        }

        @Test
        func materializeDraftMeetingPersistsMacCalendarEventPlatform() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")
            let vaultId = UUID.v7()
            try database.dbQueue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: testVaultURL.path,
                    name: "Test Vault",
                    createdAt: Date(),
                    lastOpenedAt: Date()
                ).insert(db)
            }
            let previousVault = AppSettings.shared.currentVault
            AppSettings.shared.currentVault = VaultRecord(
                id: vaultId,
                path: testVaultURL.path,
                name: "Test Vault",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            defer { AppSettings.shared.currentVault = previousVault }

            viewModel.beginDraftMeeting(
                from: CalendarEvent(
                    id: "local::mac-event-1",
                    calendarID: "local",
                    calendarName: "Local",
                    calendarColorHex: "#FF9500",
                    platform: CalendarEventPlatform.macOSCalendar,
                    platformId: "mac-event-1::1776384000",
                    title: "Mac event review",
                    description: "Local calendar notes",
                    icalUid: "mac-event-1@local",
                    startDate: Date(timeIntervalSince1970: 1_776_384_000),
                    endDate: Date(timeIntervalSince1970: 1_776_387_600),
                    isAllDay: false,
                    meetingURL: URL(string: "https://zoom.us/j/123456789")
                ),
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )

            let meetingId = try #require(viewModel.materializeDraftMeeting())
            let persisted = try database.dbQueue.read { db in
                let calendarEvent = try CalendarEventRecord.filter(Column("meetingId") == meetingId).fetchOne(db)
                return try #require(calendarEvent)
            }

            #expect(persisted.platform == "MacOSCalendar")
            #expect(persisted.platformId == "mac-event-1::1776384000")
            #expect(persisted.meetingUrl == "https://zoom.us/j/123456789")
        }

    }

    private final class MutableMicrophoneInputProvider: @unchecked Sendable {
        var defaultDeviceID: AudioDeviceID
        var devices: [MicrophoneDevice]

        init(defaultDeviceID: AudioDeviceID, devices: [MicrophoneDevice]) {
            self.defaultDeviceID = defaultDeviceID
            self.devices = devices
        }
    }

#elseif canImport(XCTest)
    import XCTest

    @MainActor
    final class CaptionViewModelTests: XCTestCase {
        private let testVaultURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        func testSelectingActiveRecordingMeetingKeepsLiveTranscriptStore() throws {
            let viewModel = CaptionViewModel()
            let dbQueue = try DatabaseQueue(path: ":memory:")
            let meetingId = UUID.v7()
            let initialSegment = TranscriptSegment(
                startTime: Date(),
                text: "live transcript",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            viewModel.isListening = true
            viewModel.currentMeetingId = meetingId
            viewModel.currentVaultURL = testVaultURL
            viewModel.store.loadSegments([initialSegment])

            let storeIdentity = ObjectIdentifier(viewModel.store)

            viewModel.loadMeeting(
                meetingId,
                dbQueue: dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: testVaultURL
            )

            XCTAssertEqual(ObjectIdentifier(viewModel.store), storeIdentity)
            XCTAssertEqual(viewModel.store.segments, [initialSegment])
            XCTAssertEqual(viewModel.recordingMeetingId, meetingId)
        }

        func testCurrentMeetingHasTranscriptSegmentsTracksStoreContents() {
            let viewModel = CaptionViewModel()
            let segment = TranscriptSegment(
                startTime: Date(),
                text: "confirmed transcript",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            XCTAssertFalse(viewModel.currentMeetingHasTranscriptSegments)

            viewModel.store.loadSegments([segment])
            XCTAssertTrue(viewModel.currentMeetingHasTranscriptSegments)

            viewModel.store.clear()
            XCTAssertFalse(viewModel.currentMeetingHasTranscriptSegments)
        }

        func testBeginDraftMeetingDoesNotPersistMeetingRecord() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")
            let event = GoogleCalendarEvent(
                id: "primary::event-1",
                calendarID: "primary",
                calendarName: "Primary",
                calendarColorHex: "#4285F4",
                platformId: "event-1",
                title: "Design review",
                description: "Review launch checklist",
                icalUid: "event-1@google.com",
                startDate: Date(timeIntervalSince1970: 1_776_384_000),
                endDate: Date(timeIntervalSince1970: 1_776_387_600),
                isAllDay: false,
                meetingURL: URL(string: "https://meet.google.com/test-link")
            )
            let vaultId = UUID.v7()
            try database.dbQueue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: testVaultURL.path,
                    name: "Test Vault",
                    createdAt: Date(),
                    lastOpenedAt: Date()
                ).insert(db)
            }

            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )

            let counts = try database.dbQueue.read { db in
                try (
                    MeetingRecord.fetchCount(db),
                    CalendarEventRecord.fetchCount(db)
                )
            }

            XCTAssertTrue(viewModel.hasDraftMeeting)
            XCTAssertEqual(viewModel.draftMeetingTitle, "Design review")
            XCTAssertEqual(counts.0, 0)
            XCTAssertEqual(counts.1, 0)
        }

        func testClearCurrentMeetingDiscardsDraftMeeting() throws {
            let viewModel = CaptionViewModel()
            let event = GoogleCalendarEvent(
                id: "primary::event-1",
                calendarID: "primary",
                calendarName: "Primary",
                calendarColorHex: "#4285F4",
                platformId: "event-1",
                title: "Design review",
                description: "",
                icalUid: "event-1@google.com",
                startDate: Date(timeIntervalSince1970: 1_776_384_000),
                endDate: Date(timeIntervalSince1970: 1_776_387_600),
                isAllDay: false,
                meetingURL: nil
            )

            let dbQueue = try DatabaseQueue(path: ":memory:")
            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: dbQueue,
                vaultURL: testVaultURL
            )
            viewModel.clearCurrentMeeting()

            XCTAssertFalse(viewModel.hasDraftMeeting)
            XCTAssertNil(viewModel.currentMeetingId)
        }

        func testMaterializeDraftMeetingPersistsMeetingAndCalendarEvent() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")
            let vaultId = UUID.v7()
            try database.dbQueue.write { db in
                try VaultRecord(
                    id: vaultId,
                    path: testVaultURL.path,
                    name: "Test Vault",
                    createdAt: Date(),
                    lastOpenedAt: Date()
                ).insert(db)
            }
            let previousVault = AppSettings.shared.currentVault
            AppSettings.shared.currentVault = VaultRecord(
                id: vaultId,
                path: testVaultURL.path,
                name: "Test Vault",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            defer { AppSettings.shared.currentVault = previousVault }

            viewModel.beginDraftMeeting(
                from: GoogleCalendarEvent(
                    id: "primary::event-1",
                    calendarID: "primary",
                    calendarName: "Primary",
                    calendarColorHex: "#4285F4",
                    platformId: "event-1",
                    title: "Design review",
                    description: "Review launch checklist",
                    icalUid: "event-1@google.com",
                    startDate: Date(timeIntervalSince1970: 1_776_384_000),
                    endDate: Date(timeIntervalSince1970: 1_776_387_600),
                    isAllDay: false,
                    meetingURL: URL(string: "https://meet.google.com/test-link")
                ),
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )

            let meetingId = try XCTUnwrap(viewModel.materializeDraftMeeting())
            let persisted = try database.dbQueue.read { db in
                try (
                    XCTUnwrap(MeetingRecord.fetchOne(db, key: meetingId)),
                    XCTUnwrap(CalendarEventRecord.filter(Column("meetingId") == meetingId).fetchOne(db))
                )
            }

            XCTAssertEqual(persisted.0.name, "Design review")
            XCTAssertEqual(persisted.1.platformId, "event-1")
            XCTAssertEqual(persisted.1.meetingUrl, "https://meet.google.com/test-link")
            XCTAssertFalse(viewModel.hasDraftMeeting)
            XCTAssertEqual(viewModel.currentMeetingId, meetingId)
        }
    }
#endif
