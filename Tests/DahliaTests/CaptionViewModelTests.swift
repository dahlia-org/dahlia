import CoreAudio
import Dispatch
import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct CaptionViewModelTests {
        private let testVaultURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        @Test
        func recordingStartReservationRejectsMeetingCreationAndDraftMaterialization() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")
            let event = CalendarEvent(
                id: "primary::event-1",
                calendarID: "primary",
                calendarName: "Primary",
                calendarColorHex: nil,
                platformId: "event-1",
                title: "Design review",
                description: "",
                icalUid: "event-1@google.com",
                startDate: Date(timeIntervalSince1970: 1_776_384_000),
                endDate: Date(timeIntervalSince1970: 1_776_387_600),
                isAllDay: false,
                conferenceURI: nil
            )
            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )
            let draftId = viewModel.draftMeeting?.id

            _ = try #require(viewModel.reserveRecordingStart())
            let recordingMeetingId = UUID.v7()
            viewModel.currentMeetingId = recordingMeetingId
            viewModel.createEmptyMeeting(
                dbQueue: database.dbQueue,
                projectURL: nil,
                vaultId: UUID.v7(),
                projectId: nil,
                vaultURL: testVaultURL
            )
            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )

            #expect(viewModel.isRecordingLifecycleBusy)
            #expect(!viewModel.canBeginRecording)
            #expect(viewModel.reserveRecordingStart() == nil)
            #expect(viewModel.currentMeetingId == recordingMeetingId)
            #expect(viewModel.draftMeeting?.id == draftId)
            #expect(viewModel.materializeDraftMeeting(customerIntelligenceIngestion: .afterMeetingPersistence) == nil)
        }

        @Test
        func systemDefaultMicrophoneSelectionResolvesCurrentDefaultDevice() async {
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
            await viewModel.refreshAvailableMicrophones()

            #expect(viewModel.microphoneSelection == MicrophoneSelection.systemDefault)
            #expect(viewModel.selectedMicrophoneID == 101)
            #expect(viewModel.microphoneCaptureDeviceID == nil)

            inputProvider.defaultDeviceID = 202
            await viewModel.refreshAvailableMicrophones()

            #expect(viewModel.selectedMicrophoneID == 202)
            #expect(viewModel.microphoneCaptureDeviceID == nil)
        }

        @Test
        func explicitMicrophoneSelectionPinsCaptureDevice() {
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [MicrophoneDevice(id: 101, name: "USB Mic")] },
                defaultInputDeviceIDProvider: { AudioDeviceID(202) }
            )

            viewModel.microphoneSelection = .device(101)

            #expect(viewModel.microphoneCaptureDeviceID == 101)
        }

        @Test
        func missingSelectedMicrophoneFallsBackToSystemDefaultSelection() async {
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
            await viewModel.refreshAvailableMicrophones()

            viewModel.microphoneSelection = .device(101)
            inputProvider.devices = [MicrophoneDevice(id: 202, name: "MacBook Pro Mic")]
            await viewModel.refreshAvailableMicrophones()

            #expect(viewModel.microphoneSelection == MicrophoneSelection.systemDefault)
            #expect(viewModel.selectedMicrophoneID == 202)
        }

        @Test
        func transientEmptyDeviceListDoesNotDiscardExplicitSelection() async {
            let inputProvider = MutableMicrophoneInputProvider(
                defaultDeviceID: AudioDeviceID(101),
                devices: [MicrophoneDevice(id: 101, name: "USB Mic")]
            )
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { inputProvider.devices },
                defaultInputDeviceIDProvider: { inputProvider.defaultDeviceID }
            )
            await viewModel.refreshAvailableMicrophones()
            viewModel.microphoneSelection = .device(101)

            inputProvider.devices = []
            inputProvider.defaultDeviceID = nil
            await viewModel.refreshAvailableMicrophones()

            #expect(viewModel.microphoneSelection == .device(101))
            #expect(viewModel.isMicEnabled)
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
        func conversationAnalyticsWaitsWhileCurrentMeetingFinalizes() {
            let viewModel = CaptionViewModel()
            let meetingId = UUID()
            viewModel.currentMeetingId = meetingId
            viewModel.isFinalizingRecording = true

            #expect(viewModel.recordingMeetingId == meetingId)
            #expect(viewModel.isCurrentMeetingConversationAnalysisPending)

            viewModel.isFinalizingRecording = false
            #expect(!viewModel.isCurrentMeetingConversationAnalysisPending)
        }

        @Test
        func conversationAnalyticsWaitsForBatchTranscriptionWithExistingTranscript() async {
            let viewModel = CaptionViewModel()
            let meetingId = UUID()
            let sessionId = UUID()
            viewModel.currentMeetingId = meetingId
            viewModel.store.loadSegments([
                TranscriptSegment(
                    startTime: .now,
                    text: "existing transcript",
                    isConfirmed: true,
                    speakerLabel: "mic"
                ),
            ])

            await viewModel.handleBatchTranscriptionUpdate(
                BatchTranscriptionUpdate(
                    meetingId: meetingId,
                    state: .running(sessionId: sessionId)
                )
            )

            #expect(viewModel.currentMeetingHasTranscriptSegments)
            #expect(viewModel.isCurrentMeetingConversationAnalysisPending)
        }

        @Test
        func conversationAnalyticsWaitsOnlyForTheMeetingWithFailedPersistence() {
            let currentMeetingId = UUID()
            let otherMeetingId = UUID()

            #expect(CaptionViewModel.conversationAnalysisIsPending(
                currentMeetingId: currentMeetingId,
                recordingMeetingId: nil,
                isListening: false,
                isFinalizingRecording: false,
                isBatchTranscriptionPending: false,
                failedPersistenceMeetingId: currentMeetingId
            ))
            #expect(!CaptionViewModel.conversationAnalysisIsPending(
                currentMeetingId: otherMeetingId,
                recordingMeetingId: currentMeetingId,
                isListening: false,
                isFinalizingRecording: false,
                isBatchTranscriptionPending: false,
                failedPersistenceMeetingId: currentMeetingId
            ))
        }

        @Test
        func structuredActionItemsCountAsDisplayableSummaryContent() {
            let viewModel = CaptionViewModel()
            viewModel.currentSummaryDocument = SummaryDocument(
                title: "",
                sections: [],
                actionItems: [SummaryActionItem(title: "Send notes", assignee: "Aki")]
            )

            #expect(viewModel.hasCurrentMeetingSummary)
        }

        @Test
        func canGenerateSummaryIsDisabledWhileListening() {
            let viewModel = summaryReadyViewModel()

            #expect(viewModel.canGenerateSummary)

            viewModel.isListening = true

            #expect(!viewModel.canGenerateSummary)
        }

        @Test
        func canGenerateSummaryIsDisabledWhileFinalizingRecording() {
            let viewModel = summaryReadyViewModel()

            #expect(viewModel.canGenerateSummary)

            viewModel.isFinalizingRecording = true

            #expect(!viewModel.canGenerateSummary)
        }

        @Test
        func vaultSwitchingIsDisabledWhileFinalizingRecording() {
            let viewModel = CaptionViewModel()

            #expect(viewModel.canSwitchVault)

            viewModel.isFinalizingRecording = true

            #expect(!viewModel.canSwitchVault)
        }

        @Test
        func canGenerateSummaryRemainsEnabledWhileAnotherMeetingSummaryIsGenerating() {
            let viewModel = summaryReadyViewModel()
            let currentMeetingID = viewModel.currentMeetingId

            #expect(viewModel.canGenerateSummary)

            viewModel.summaryGeneratingMeetingIDs = [UUID.v7()]

            #expect(viewModel.canGenerateSummary)
            #expect(currentMeetingID != nil)
        }

        @Test
        func canGenerateSummaryIsDisabledForTheGeneratingMeeting() throws {
            let viewModel = summaryReadyViewModel()
            let currentMeetingID = try #require(viewModel.currentMeetingId)

            viewModel.summaryGeneratingMeetingIDs = [currentMeetingID]

            #expect(!viewModel.canGenerateSummary)
        }

        @Test
        func manualSummaryDoesNotStartWhileFinalizingRecording() {
            let viewModel = summaryReadyViewModel()
            viewModel.isFinalizingRecording = true

            viewModel.triggerManualSummary()

            #expect(!viewModel.requestShowSummaryTab)
            #expect(viewModel.summaryGeneratingMeetingIDs.isEmpty)
        }

        @Test
        func loadMeetingDoesNotResetStoreWhileFinalizingRecording() throws {
            let viewModel = summaryReadyViewModel()
            let originalMeetingId = try #require(viewModel.currentMeetingId)
            let originalSegments = viewModel.store.segments
            let dbQueue = try DatabaseQueue(path: ":memory:")

            viewModel.isFinalizingRecording = true
            viewModel.loadMeeting(
                UUID.v7(),
                dbQueue: dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: testVaultURL
            )

            #expect(viewModel.currentMeetingId == originalMeetingId)
            #expect(viewModel.store.segments == originalSegments)
        }

        @Test
        func retryInitialMeetingLoadRestoresMetadataAsWellAsTranscriptPage() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let meetingId = UUID.v7()
            let viewModel = CaptionViewModel()
            let vault = VaultRecord(
                id: .v7(),
                path: testVaultURL.path,
                name: "Retry Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: vault.id,
                    projectId: nil,
                    name: "Recovered",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try MeetingNoteRecord(
                    meetingId: meetingId,
                    text: "metadata restored",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try db.execute(sql: "ALTER TABLE notes RENAME TO notes_unavailable")
            }

            viewModel.loadMeeting(
                meetingId,
                dbQueue: database.dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: testVaultURL
            )
            try await waitUntil { viewModel.store.requiresFullMeetingReload }
            try await database.dbQueue.write { db in
                try db.execute(sql: "ALTER TABLE notes_unavailable RENAME TO notes")
            }

            viewModel.retryInitialMeetingLoad()
            try await waitUntil {
                !viewModel.store.isLoadingInitialPage && viewModel.store.pageLoadError == nil
            }

            #expect(viewModel.noteText == "metadata restored")
            #expect(!viewModel.store.requiresFullMeetingReload)
        }

        @Test
        func clearCurrentMeetingDoesNotResetStoreWhileFinalizingRecording() throws {
            let viewModel = summaryReadyViewModel()
            let originalMeetingId = try #require(viewModel.currentMeetingId)
            let originalSegments = viewModel.store.segments

            viewModel.isFinalizingRecording = true
            viewModel.clearCurrentMeeting()

            #expect(viewModel.currentMeetingId == originalMeetingId)
            #expect(viewModel.store.segments == originalSegments)
        }

        @Test
        func createEmptyMeetingDoesNotResetStoreWhileFinalizingRecording() throws {
            let viewModel = summaryReadyViewModel()
            let originalMeetingId = try #require(viewModel.currentMeetingId)
            let originalSegments = viewModel.store.segments

            viewModel.isFinalizingRecording = true
            try viewModel.createEmptyMeeting(
                dbQueue: DatabaseQueue(path: ":memory:"),
                projectURL: nil,
                vaultId: UUID.v7(),
                projectId: nil,
                vaultURL: testVaultURL
            )

            #expect(viewModel.currentMeetingId == originalMeetingId)
            #expect(viewModel.store.segments == originalSegments)
        }

        private func summaryReadyViewModel() -> CaptionViewModel {
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

            return viewModel
        }

        @Test
        func beginDraftMeetingDoesNotPersistMeetingRecord() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")
            let event = CalendarEvent(
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
                conferenceURI: URL(string: "https://meet.google.com/test-link")
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
        func clearCurrentMeetingDiscardsDraftMeeting() throws {
            let viewModel = CaptionViewModel()
            let event = CalendarEvent(
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
                conferenceURI: nil
            )

            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: try DatabaseQueue(path: ":memory:"),
                vaultURL: testVaultURL
            )
            viewModel.clearCurrentMeeting()

            #expect(!viewModel.hasDraftMeeting)
            #expect(viewModel.currentMeetingId == nil)
        }

        @Test
        func projectNavigationPreservesDraftMeeting() throws {
            let viewModel = CaptionViewModel()
            let event = CalendarEvent(
                id: "primary::event-1",
                calendarID: "primary",
                calendarName: "Primary",
                calendarColorHex: "#4285F4",
                platformId: "event-1",
                title: "Design review",
                description: "Discuss the rollout",
                icalUid: "event-1@google.com",
                startDate: Date(timeIntervalSince1970: 1_776_384_000),
                endDate: Date(timeIntervalSince1970: 1_776_387_600),
                isAllDay: false,
                conferenceURI: nil
            )
            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: try DatabaseQueue(path: ":memory:"),
                vaultURL: testVaultURL
            )
            viewModel.updateDraftMeetingTitle("Edited title")

            viewModel.clearCurrentMeetingForProjectNavigation()

            #expect(viewModel.hasDraftMeeting)
            #expect(viewModel.draftMeetingTitle == "Edited title")
        }

        @Test
        func failedQuickRecordingPreservesDraftMeeting() async throws {
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
            viewModel.microphoneSelection = .none
            viewModel.isSystemAudioEnabled = true
            let database = try AppDatabaseManager(path: ":memory:")
            let dbQueue = database.dbQueue
            let projectId = UUID.v7()
            let projectURL = testVaultURL.appending(path: "Projects/Design", directoryHint: .isDirectory)
            let event = CalendarEvent(
                id: "primary::event-1",
                calendarID: "primary",
                calendarName: "Primary",
                calendarColorHex: "#4285F4",
                platformId: "event-1",
                title: "Design review",
                description: "Discuss the rollout",
                icalUid: "event-1@google.com",
                startDate: Date(timeIntervalSince1970: 1_776_384_000),
                endDate: Date(timeIntervalSince1970: 1_776_387_600),
                isAllDay: false,
                conferenceURI: URL(string: "https://meet.google.com/test-link")
            )
            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: dbQueue,
                projectURL: projectURL,
                projectId: projectId,
                projectName: "Projects/Design",
                vaultURL: testVaultURL
            )
            viewModel.updateDraftMeetingTitle("Edited design review")
            viewModel.noteText = "Keep this draft note"

            let databaseAccessStarted = AsyncStream<Void>.makeStream()
            let releaseDatabase = DispatchSemaphore(value: 0)
            let blockingDatabaseTask = Task.detached {
                try dbQueue.read { _ in
                    databaseAccessStarted.continuation.yield()
                    releaseDatabase.wait()
                }
                databaseAccessStarted.continuation.finish()
            }
            var databaseAccessIterator = databaseAccessStarted.stream.makeAsyncIterator()
            _ = await databaseAccessIterator.next()
            defer { releaseDatabase.signal() }

            let recordingStartTask = Task {
                await viewModel.startListening(
                    dbQueue: dbQueue,
                    projectURL: nil,
                    vaultId: UUID.v7(),
                    projectId: nil,
                    vaultURL: testVaultURL,
                    initialMeetingName: "Quick recording 2026-08-15 12:34:56",
                    usesDraftMeeting: false
                )
            }
            try await waitUntil { viewModel.currentProjectId == nil }
            viewModel.updateDraftMeetingTitle("Edited while recording starts")
            viewModel.noteText = "Keep the latest draft note"
            viewModel.setExplicitProjectContext(projectURL: nil, projectId: nil, projectName: nil)
            releaseDatabase.signal()
            await recordingStartTask.value
            try await blockingDatabaseTask.value

            #expect(viewModel.hasDraftMeeting)
            #expect(viewModel.draftMeetingTitle == "Edited while recording starts")
            #expect(viewModel.draftMeeting?.linkedCalendarEvent == event)
            #expect(viewModel.currentProjectURL == nil)
            #expect(viewModel.currentProjectId == nil)
            #expect(viewModel.currentProjectName == nil)
            #expect(viewModel.noteText == "Keep the latest draft note")
            #expect(!viewModel.isListening)
            #expect(viewModel.errorMessage != nil)
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
                from: CalendarEvent(
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
                    conferenceURI: URL(string: "https://meet.google.com/test-link")
                ),
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )

            let meetingId = try #require(
                viewModel.materializeDraftMeeting(customerIntelligenceIngestion: .afterMeetingPersistence)
            )
            let persisted = try database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
                let calendarEvent = try linkedCalendarEvent(meetingId: meetingId, in: db)
                let source = try CalendarEventSourceRecord
                    .filter(Column("platform") == CalendarEventPlatform.googleCalendar)
                    .filter(Column("platform_id") == "event-1")
                    .fetchOne(db)
                return try (
                    #require(meeting),
                    #require(calendarEvent),
                    #require(source)
                )
            }

            #expect(persisted.0.name == "Design review")
            #expect(persisted.0.calendarEventIcalUid == "event-1@google.com")
            #expect(persisted.0.calendarEventRecurrenceId?.isEmpty == true)
            #expect(persisted.1.conferenceURI == "https://meet.google.com/test-link")
            #expect(persisted.2.platformId == "event-1")
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
                    conferenceURI: URL(string: "https://zoom.us/j/123456789")
                ),
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )

            let meetingId = try #require(
                viewModel.materializeDraftMeeting(customerIntelligenceIngestion: .afterMeetingPersistence)
            )
            let persisted = try database.dbQueue.read { db in
                let calendarEvent = try linkedCalendarEvent(meetingId: meetingId, in: db)
                let source = try CalendarEventSourceRecord
                    .filter(Column("platform") == CalendarEventPlatform.macOSCalendar)
                    .filter(Column("platform_id") == "mac-event-1::1776384000")
                    .fetchOne(db)
                return try (#require(calendarEvent), #require(source))
            }

            #expect(persisted.0.icalUid == "mac-event-1@local")
            #expect(persisted.0.conferenceURI == "https://zoom.us/j/123456789")
            #expect(persisted.1.platform == CalendarEventPlatform.macOSCalendar)
        }

        private func waitUntil(
            _ condition: @escaping @MainActor () -> Bool
        ) async throws {
            for _ in 0 ..< 200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for asynchronous view model state")
        }

    }

    private final class MutableMicrophoneInputProvider: @unchecked Sendable {
        var defaultDeviceID: AudioDeviceID?
        var devices: [MicrophoneDevice]

        init(defaultDeviceID: AudioDeviceID?, devices: [MicrophoneDevice]) {
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
            let event = CalendarEvent(
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
                conferenceURI: URL(string: "https://meet.google.com/test-link")
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
            let event = CalendarEvent(
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
                conferenceURI: nil
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
                from: CalendarEvent(
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
                    conferenceURI: URL(string: "https://meet.google.com/test-link")
                ),
                dbQueue: database.dbQueue,
                vaultURL: testVaultURL
            )

            let meetingId = try XCTUnwrap(
                viewModel.materializeDraftMeeting(customerIntelligenceIngestion: .afterMeetingPersistence)
            )
            let persisted = try database.dbQueue.read { db in
                try (
                    XCTUnwrap(MeetingRecord.fetchOne(db, key: meetingId)),
                    XCTUnwrap(linkedCalendarEvent(meetingId: meetingId, in: db)),
                    XCTUnwrap(
                        CalendarEventSourceRecord
                            .filter(Column("platform") == CalendarEventPlatform.googleCalendar)
                            .filter(Column("platform_id") == "event-1")
                            .fetchOne(db)
                    )
                )
            }

            XCTAssertEqual(persisted.0.name, "Design review")
            XCTAssertEqual(persisted.0.calendarEventIcalUid, "event-1@google.com")
            XCTAssertEqual(persisted.1.conferenceURI, "https://meet.google.com/test-link")
            XCTAssertEqual(persisted.2.platformId, "event-1")
            XCTAssertFalse(viewModel.hasDraftMeeting)
            XCTAssertEqual(viewModel.currentMeetingId, meetingId)
        }
    }
#endif

private func linkedCalendarEvent(meetingId: UUID, in db: Database) throws -> CalendarEventRecord? {
    guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId),
          let icalUid = meeting.calendarEventIcalUid,
          let recurrenceId = meeting.calendarEventRecurrenceId
    else { return nil }

    return try CalendarEventRecord.fetch(
        key: CalendarEventKey(icalUid: icalUid, recurrenceId: recurrenceId),
        in: db
    )
}
