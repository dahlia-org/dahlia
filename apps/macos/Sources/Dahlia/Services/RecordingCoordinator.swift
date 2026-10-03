import Foundation
import GRDB

/// メインウィンドウ、メニューバー、ツールバーから共通利用する録音開始ロジック。
@MainActor
final class RecordingCoordinator {
    private let isAppReady: @MainActor () -> Bool
    private let viewModel: CaptionViewModel
    private let sidebarViewModel: SidebarViewModel
    private let mainWindowNavigation: MainWindowNavigation
    private let notifyRecordingDidStart: @MainActor () -> Void
    private let notifyRecordingDidStop: @MainActor () -> Void
    private let meetingLinkOpener: MeetingLinkOpener

    init(
        viewModel: CaptionViewModel,
        sidebarViewModel: SidebarViewModel,
        mainWindowNavigation: MainWindowNavigation,
        onRecordingDidStart: @escaping @MainActor () -> Void,
        onRecordingDidStop: @escaping @MainActor () -> Void,
        meetingLinkOpener: MeetingLinkOpener = MeetingLinkOpener(),
        isAppReady: @escaping @MainActor () -> Bool = { true }
    ) {
        self.isAppReady = isAppReady
        self.viewModel = viewModel
        self.sidebarViewModel = sidebarViewModel
        self.mainWindowNavigation = mainWindowNavigation
        self.notifyRecordingDidStart = onRecordingDidStart
        self.notifyRecordingDidStop = onRecordingDidStop
        self.meetingLinkOpener = meetingLinkOpener
    }

    var canStartNewMeeting: Bool {
        isAppReady() && viewModel.canBeginRecording
            && sidebarViewModel.dbQueue != nil
            && sidebarViewModel.currentWorkspace.map(\.allowsCanonicalEdits) == true
    }

    func startNewMeeting() {
        startNewMeeting(opensMainWindowOnFailure: true)
    }

    func startQuickRecording() {
        startNewMeeting(
            opensMainWindowOnFailure: true,
            initialMeetingName: QuickRecordingMeetingTitle.make(at: .now),
            usesDraftMeeting: false,
            recordingTrigger: .quick
        )
    }

    private func startNewMeeting(
        opensMainWindowOnFailure: Bool,
        initialMeetingName: String = "",
        usesDraftMeeting: Bool = true,
        recordingTrigger: UsageTelemetryEvent.RecordingTrigger? = nil
    ) {
        mainWindowNavigation.showMeetings()
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let workspace = sidebarViewModel.currentWorkspace,
              let reservation = viewModel.reserveRecordingStart() else {
            openMainWindowOnFailure(if: opensMainWindowOnFailure)
            return
        }

        let shouldUseDraftMeeting = usesDraftMeeting && viewModel.hasDraftMeeting
        let preservesDraftUntilStart = !usesDraftMeeting && viewModel.hasDraftMeeting
        let projectURL = shouldUseDraftMeeting ? viewModel.currentProjectURL : nil
        let projectId = shouldUseDraftMeeting ? viewModel.currentProjectId : nil
        let projectName = shouldUseDraftMeeting ? viewModel.currentProjectName : nil

        if !shouldUseDraftMeeting, !preservesDraftUntilStart {
            viewModel.clearCurrentMeeting()
        }

        Task {
            await viewModel.startListening(
                dbQueue: dbQueue,
                projectURL: projectURL,
                workspaceId: workspace.id,
                projectId: projectId,
                projectName: projectName,
                workspaceURL: workspace.url,
                initialMeetingName: initialMeetingName,
                usesDraftMeeting: usesDraftMeeting,
                recordingTrigger: recordingTrigger,
                reservation: reservation
            )
            recordingDidStart()
            if let newMeetingId = viewModel.currentMeetingId {
                sidebarViewModel.selectMeeting(newMeetingId)
            }
        }
    }

    func createDraftMeeting() {
        createDraftMeeting(project: nil)
    }

    func createDraftMeeting(in project: ProjectOverviewItem) {
        createDraftMeeting(project: project)
    }

    private func createDraftMeeting(project: ProjectOverviewItem?) {
        guard isAppReady(), sidebarViewModel.canEditCurrentWorkspace,
              !viewModel.isRecordingStartPending,
              !viewModel.isFinalizingRecording else { return }
        mainWindowNavigation.showMeetings()
        guard let dbQueue = sidebarViewModel.dbQueue,
              let workspace = sidebarViewModel.currentWorkspace else {
            MainWindowOpener.shared.openMainWindow()
            return
        }

        sidebarViewModel.clearMeetingSelection()
        viewModel.beginDraftMeeting(
            dbQueue: dbQueue,
            projectURL: project.flatMap { project in
                workspace.url?.appending(path: project.projectName, directoryHint: .isDirectory)
            },
            projectId: project?.projectId,
            projectName: project?.projectName,
            workspaceURL: workspace.url
        )
        recordDraftNavigation()
    }

    func createEmptyMeeting() {
        mainWindowNavigation.showMeetings()
        guard isAppReady(), sidebarViewModel.canEditCurrentWorkspace else { return }
        guard let dbQueue = sidebarViewModel.dbQueue,
              let workspace = sidebarViewModel.currentWorkspace else {
            MainWindowOpener.shared.openMainWindow()
            return
        }

        guard let meetingId = viewModel.createEmptyMeeting(
            dbQueue: dbQueue,
            projectURL: nil,
            workspaceId: workspace.id,
            projectId: nil,
            name: "",
            projectName: nil,
            workspaceURL: workspace.url
        ) else { return }
        sidebarViewModel.selectMeeting(meetingId)
    }

    func openCalendarEvent(_ event: CalendarEvent) {
        mainWindowNavigation.openMeetings()
        guard isAppReady(), let dbQueue = sidebarViewModel.dbQueue,
              let workspace = sidebarViewModel.currentWorkspace else { return }

        let repository = MeetingRepository(dbQueue: dbQueue)
        do {
            if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(
                event,
                workspaceId: workspace.id
            ) {
                sidebarViewModel.selectMeeting(existingMeetingId)
                return
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "calendarEventSelection"])
            return
        }

        guard sidebarViewModel.canEditCurrentWorkspace, !viewModel.isListening else { return }

        sidebarViewModel.clearMeetingSelection()
        viewModel.beginDraftMeeting(
            from: event,
            dbQueue: dbQueue,
            workspaceURL: workspace.url
        )
        recordDraftNavigation()
    }

    func joinCalendarEventAndStartRecording(_ event: CalendarEvent) {
        openMeetingLink(for: event)
        _ = startRecording(forCalendarEvent: event)
    }

    func openMeetingLink(for event: CalendarEvent) {
        guard let conferenceURI = event.conferenceURI else { return }
        meetingLinkOpener.open(conferenceURI)
    }

    func startAutomaticRecording(forCalendarEvent event: CalendarEvent) {
        mainWindowNavigation.openMeetingsWithoutActivation()
        startRecording(
            forCalendarEvent: event,
            opensMainWindowOnFailure: false,
            recordingTrigger: .scheduled
        )
    }

    @discardableResult
    func startRecording(appendingTo meetingId: UUID) -> Bool {
        startRecording(
            appendingTo: meetingId,
            opensMainWindowOnFailure: true
        )
    }

    @discardableResult
    private func startRecording(
        appendingTo meetingId: UUID,
        opensMainWindowOnFailure: Bool,
        recordingTrigger: UsageTelemetryEvent.RecordingTrigger? = nil
    ) -> Bool {
        mainWindowNavigation.showMeetings()
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let workspace = sidebarViewModel.currentWorkspace else {
            openMainWindowOnFailure(if: opensMainWindowOnFailure)
            return false
        }

        let item: MeetingSidebarItem
        do {
            guard let fetchedItem = try dbQueue.read({ db in
                try MeetingRepository.fetchMeetingSidebarItems(
                    ids: [meetingId],
                    workspaceId: workspace.id,
                    in: db
                ).first
            }) else {
                openMainWindowOnFailure(if: opensMainWindowOnFailure)
                return false
            }
            item = fetchedItem
        } catch {
            viewModel.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "recordingAppendTarget"])
            openMainWindowOnFailure(if: opensMainWindowOnFailure)
            return false
        }

        guard let reservation = viewModel.reserveRecordingStart() else { return false }

        Task {
            await viewModel.startListening(
                dbQueue: dbQueue,
                projectURL: item.projectName.flatMap { sidebarViewModel.projectURL(for: $0) },
                workspaceId: workspace.id,
                projectId: item.projectId,
                projectName: item.projectName,
                workspaceURL: workspace.url,
                recordingTrigger: recordingTrigger,
                appendingTo: meetingId,
                reservation: reservation
            )
            recordingDidStart()
            sidebarViewModel.selectMeeting(meetingId)
        }
        return true
    }

    func stopRecording() {
        notifyRecordingDidStop()
        viewModel.stopListening()
    }

    func recordingDidStart() {
        guard viewModel.isListening else { return }
        notifyRecordingDidStart()
    }

    @discardableResult
    private func startRecording(
        forCalendarEvent event: CalendarEvent,
        opensMainWindowOnFailure: Bool = true,
        recordingTrigger: UsageTelemetryEvent.RecordingTrigger? = nil
    ) -> Bool {
        mainWindowNavigation.showMeetings()
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let workspace = sidebarViewModel.currentWorkspace else {
            openMainWindowOnFailure(if: opensMainWindowOnFailure)
            return false
        }

        let repository = MeetingRepository(dbQueue: dbQueue)
        do {
            if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(
                event,
                workspaceId: workspace.id
            ) {
                sidebarViewModel.selectMeeting(existingMeetingId)
                return startRecording(
                    appendingTo: existingMeetingId,
                    opensMainWindowOnFailure: opensMainWindowOnFailure,
                    recordingTrigger: recordingTrigger
                )
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "calendarEventRecording"])
            return false
        }

        sidebarViewModel.clearMeetingSelection()
        viewModel.beginDraftMeeting(
            from: event,
            dbQueue: dbQueue,
            workspaceURL: workspace.url
        )
        startNewMeeting(
            opensMainWindowOnFailure: opensMainWindowOnFailure,
            recordingTrigger: recordingTrigger
        )
        return true
    }

    private func openMainWindowOnFailure(if shouldOpen: Bool) {
        guard shouldOpen else { return }
        MainWindowOpener.shared.openMainWindow()
    }

    private func recordDraftNavigation() {
        guard let draftMeeting = viewModel.draftMeeting else { return }
        mainWindowNavigation.recordNavigation(to: .meetingDraft(draftMeeting, noteText: viewModel.noteText))
    }
}
