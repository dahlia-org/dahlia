import AppKit
import SwiftUI

enum WindowID {
    static let main = "main"
    static let organizationWorkspace = "organization-workspace"
    static let audioRecognitionTest = "audio-recognition-test"
    static let applicationLogs = "application-logs"
    static let codexChat = "codex-chat"
}

private enum MainWindowMetrics {
    static let minimumWidth: CGFloat = 720
    static let minimumHeight: CGFloat = 520
    static let defaultWidth: CGFloat = 1120
    static let defaultHeight: CGFloat = 740
}

@main
struct DahliaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var updateController: AppUpdateController
    @StateObject private var viewModel: CaptionViewModel
    @State private var sidebarViewModel: SidebarViewModel
    @StateObject private var meetingDetectionService: MeetingDetectionService
    @StateObject private var liveSubtitleOverlayService: LiveSubtitleOverlayService
    @State private var liveSubtitleOverlayCoordinator: LiveSubtitleOverlayCoordinator
    @State private var recordingCoordinator: RecordingCoordinator
    @State private var menuBarCalendarViewModel: MenuBarCalendarViewModel
    @State private var chatCoordinator: CodexChatCoordinator
    @State private var vaultManagementModel: VaultManagementModel
    @State private var dahliaAccountController = DahliaCloudAccountController.shared
    @State private var tokenBroker = DahliaTokenBrokerServer()
    private let mainWindowNavigation: MainWindowNavigation
    @State private var appDatabase: AppDatabaseManager?
    @State private var meetingSyncWorker: SyncWorker?
    @State private var isInitializingVault = true
    @State private var vaultInitializationTask: Task<Void, Never>?
    @State private var showVaultPicker = true
    @State private var pendingSetupAdoptionVaultID: UUID?

    @MainActor
    init() {
        let updateController = AppUpdateController()
        let viewModel = CaptionViewModel()
        let sidebarViewModel = SidebarViewModel()
        let liveSubtitleOverlayService = LiveSubtitleOverlayService()
        let mainWindowNavigation = MainWindowNavigation.shared
        let meetingDetectionService = MeetingDetectionService()
        let recordingCoordinator = RecordingCoordinator(
            viewModel: viewModel,
            sidebarViewModel: sidebarViewModel,
            mainWindowNavigation: mainWindowNavigation,
            onRecordingDidStart: meetingDetectionService.recordingDidStart,
            onRecordingDidStop: meetingDetectionService.recordingDidStop
        )
        let menuBarCalendarViewModel = MenuBarCalendarViewModel()
        let liveSubtitleOverlayCoordinator = LiveSubtitleOverlayCoordinator(
            viewModel: viewModel,
            liveSubtitleOverlayService: liveSubtitleOverlayService
        )
        let chatCoordinator = CodexChatCoordinator()
        chatCoordinator.liveModeStatusDidChange = { [weak viewModel] isEnabled in
            viewModel?.setChatLiveModeEnabled(isEnabled)
        }
        viewModel.finalizedLiveTranscriptHandler = { [weak chatCoordinator] text, wasTruncated in
            chatCoordinator?.receiveFinalizedLiveTranscript(text, wasTruncated: wasTruncated)
        }
        viewModel.chatLiveModeFailureHandler = { [weak chatCoordinator] in
            chatCoordinator?.disableLiveMode()
        }

        _viewModel = StateObject(wrappedValue: viewModel)
        _updateController = State(initialValue: updateController)
        _sidebarViewModel = State(initialValue: sidebarViewModel)
        _meetingDetectionService = StateObject(wrappedValue: meetingDetectionService)
        _liveSubtitleOverlayService = StateObject(wrappedValue: liveSubtitleOverlayService)
        _recordingCoordinator = State(initialValue: recordingCoordinator)
        _menuBarCalendarViewModel = State(initialValue: menuBarCalendarViewModel)
        _liveSubtitleOverlayCoordinator = State(initialValue: liveSubtitleOverlayCoordinator)
        _chatCoordinator = State(initialValue: chatCoordinator)
        _vaultManagementModel = State(initialValue: VaultManagementModel())
        self.mainWindowNavigation = mainWindowNavigation
    }

    var body: some Scene {
        Window(L10n.dahlia, id: WindowID.main) {
            ZStack {
                Group {
                    if isInitializingVault {
                        VStack(spacing: 0) {
                            DahliaWindowHeader(reservesWindowControls: true) {
                                Spacer()
                            }
                            ProgressView(L10n.loadingVaults)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if let setupTourMode = mainWindowNavigation.setupTourMode {
                        SetupTourView(
                            mode: setupTourMode,
                            currentVault: AppSettings.shared.currentVault,
                            vaultManagementModel: vaultManagementModel,
                            accountController: dahliaAccountController,
                            canComplete: { viewModel.canSwitchVault },
                            onComplete: completeSetupTour
                        )
                    } else if showVaultPicker {
                        VaultPickerView(
                            appDatabase: appDatabase,
                            model: vaultManagementModel,
                            canSwitchVault: viewModel.canSwitchVault,
                            captionViewModel: viewModel,
                            sidebarViewModel: sidebarViewModel,
                            mainWindowNavigation: mainWindowNavigation,
                            updateController: updateController
                        ) { vault in
                            openVault(vault)
                        }
                    } else {
                        ContentView(
                            viewModel: viewModel,
                            updateController: updateController,
                            sidebarViewModel: sidebarViewModel,
                            recordingCoordinator: recordingCoordinator,
                            chatCoordinator: chatCoordinator,
                            mainWindowNavigation: mainWindowNavigation,
                            appDatabase: appDatabase,
                            vaultManagementModel: vaultManagementModel,
                            onSelectVault: { vault in openVault(vault) }
                        )
                    }
                }
                .disabled(mainWindowNavigation.isShowingDahliaSignIn)
                .accessibilityHidden(mainWindowNavigation.isShowingDahliaSignIn)

                if mainWindowNavigation.isShowingDahliaSignIn {
                    DahliaServerSignInView(
                        cloudConfiguration: dahliaAccountController.defaultConfiguration,
                        allowsCloudSignIn: dahliaAccountController.cloudConnection == nil,
                        isBusy: dahliaAccountController.isBusy,
                        isSigningIn: dahliaAccountController.isSigningIn,
                        errorMessage: dahliaAccountController.errorMessage,
                        onCancel: cancelDahliaSignIn,
                        onSignIn: signInToDahlia
                    )
                }
            }
            .dahliaAppearance()
            .frame(
                minWidth: MainWindowMetrics.minimumWidth,
                minHeight: MainWindowMetrics.minimumHeight
            )
            .dahliaSimpleWindowStyle()
            .alert(
                L10n.vaultOperationFailed,
                isPresented: Binding(
                    get: { vaultManagementModel.isShowingError },
                    set: { vaultManagementModel.isShowingError = $0 }
                )
            ) {} message: {
                Text(vaultManagementModel.errorMessage)
            }
            .confirmationDialog(
                vaultManagementModel.pendingServerAdoption.map {
                    L10n.adoptVaultOnServerTitle($0.vault.name, serverVaultExists: $0.serverVault != nil)
                } ?? "",
                isPresented: Binding(
                    get: { vaultManagementModel.pendingServerAdoption != nil },
                    set: { if !$0 { cancelServerAdoption() } }
                ),
                titleVisibility: .visible
            ) {
                if let pending = vaultManagementModel.pendingServerAdoption {
                    Button(pending.serverVault == nil ? L10n.moveVaultToServer : L10n.reconnectServerVault) {
                        Task { await confirmServerAdoption(pending) }
                    }
                }
                Button(L10n.keepLocalAccount, role: .cancel) {
                    cancelServerAdoption()
                }
            } message: {
                if let pending = vaultManagementModel.pendingServerAdoption {
                    Text(L10n.adoptVaultOnServerDescription(serverVaultExists: pending.serverVault != nil))
                }
            }
            .confirmationDialog(
                dahliaAccountController.pendingSignOutConnection.map {
                    L10n.signOutDahliaConnection($0.displayName)
                } ?? "",
                isPresented: Binding(
                    get: { dahliaAccountController.pendingSignOutConnection != nil },
                    set: { if !$0 { dahliaAccountController.cancelSignOut() } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.moveVaultsToLocalAndSignOut) {
                    dahliaAccountController.confirmSignOut(disposition: .moveToLocalAccount)
                }
                Button(L10n.deleteLocalVaultsAndSignOut, role: .destructive) {
                    dahliaAccountController.confirmSignOut(disposition: .deleteLocalCopies)
                }
                Button(L10n.cancel, role: .cancel) {
                    dahliaAccountController.cancelSignOut()
                }
            } message: {
                Text(L10n.signOutVaultDispositionDescription)
            }
            .sheet(item: $viewModel.pendingBatchTranscriptionConfirmation) { confirmation in
                BatchTranscriptionConfirmationView(
                    locales: viewModel.batchTranscriptionLocaleOptions(
                        preferredIdentifier: confirmation.suggestedLocaleIdentifier
                    ),
                    automaticLanguageLocales: viewModel.batchTranscriptionAutomaticLanguageCandidates(
                        snapshot: confirmation.automaticLanguageCandidateSnapshot
                    ).locales,
                    displayLocale: AppSettings.shared.appLanguage.locale,
                    projects: confirmation.projectSelection.projects,
                    initialProjectId: confirmation.projectSelection.selectedProjectId,
                    initialErrorMessage: confirmation.projectSelection.errorMessage,
                    initialLanguageSelection: confirmation.initialLanguageSelection,
                    allowsRecordedLanguageSelection: confirmation.allowsRecordedLanguageSelection,
                    initiallyGeneratesSummary: confirmation.initiallyGeneratesSummary,
                    summaryGenerationOptions: confirmation.summaryGenerationOptions,
                    isRetranscription: confirmation.isRetranscription,
                    onStart: { languageSelection, generatesSummary, summaryOptions, projectId in
                        if let error = viewModel.assignPendingBatchTranscriptionProject(projectId) {
                            return error
                        }
                        viewModel.confirmBatchTranscription(
                            languageSelection: languageSelection,
                            generatesSummary: generatesSummary,
                            summaryGenerationOptions: summaryOptions
                        )
                        return nil
                    },
                    onPostpone: viewModel.postponeBatchTranscription
                )
                .interactiveDismissDisabled()
            }
            .task {
                _ = liveSubtitleOverlayCoordinator
                await initializeAppIfNeeded()
                let settings = AppSettings.shared
                async let driveRestore: Void = GoogleDriveStore.shared.restoreSessionIfNeeded()
                await CalendarSourceCoordinator.shared.refreshEnabledSources(settings.enabledCalendarSources)
                await driveRestore
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, let meetingSyncWorker else { return }
                Task { await meetingSyncWorker.applicationBecameActive() }
            }
            .onChange(of: dahliaAccountController.connections) {
                Task { await reconcileVaultsAfterAccountChange() }
            }
            .modifier(MainWindowOpenWindowRegistrationModifier())
            .environment(mainWindowNavigation)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: MainWindowMetrics.defaultWidth, height: MainWindowMetrics.defaultHeight)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.createNewMeeting, action: recordingCoordinator.createEmptyMeeting)
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(
                        showVaultPicker
                            || mainWindowNavigation.isShowingSettings
                            || mainWindowNavigation.isShowingDahliaSignIn
                            || !sidebarViewModel.canEditCurrentVault
                    )
            }
            SettingsCommands(mainWindowNavigation: mainWindowNavigation)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updateController.updater)
            }
            OrganizationWorkspaceCommands()
        }

        WindowGroup(L10n.chat, id: WindowID.codexChat, for: CodexChatSessionID.self) { $sessionID in
            Group {
                if let sessionID {
                    CodexChatWindowView(
                        coordinator: chatCoordinator,
                        sidebarViewModel: sidebarViewModel,
                        sessionID: sessionID
                    )
                } else {
                    VStack(spacing: 0) {
                        DahliaWindowHeader(reservesWindowControls: true) {
                            Spacer()
                        }
                        ContentUnavailableView(
                            L10n.chatWindowUnavailable,
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .environment(mainWindowNavigation)
            .dahliaAppearance()
            .dahliaSimpleWindowStyle()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.customerIntelligence, id: WindowID.organizationWorkspace) {
            OrganizationWorkspaceView(
                sidebarViewModel: sidebarViewModel,
                chatCoordinator: chatCoordinator,
                mainWindowNavigation: mainWindowNavigation
            )
            .dahliaAppearance()
            .dahliaSimpleWindowStyle()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 820)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.audioRecognitionTest, id: WindowID.audioRecognitionTest) {
            VStack(spacing: 0) {
                DahliaWindowHeader(reservesWindowControls: true) {
                    Spacer()
                }
                MicrophoneRecognitionTestView(captionViewModel: viewModel)
            }
            .dahliaAppearance()
            .dahliaSimpleWindowStyle()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.applicationLogs, id: WindowID.applicationLogs) {
            ApplicationLogView()
                .dahliaAppearance()
                .dahliaSimpleWindowStyle()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        MenuBarExtra {
            MenuBarMenuView(
                viewModel: viewModel,
                recordingCoordinator: recordingCoordinator,
                calendarViewModel: menuBarCalendarViewModel,
                mainWindowNavigation: mainWindowNavigation
            )
        } label: {
            MenuBarLabel(
                viewModel: viewModel,
                calendarViewModel: menuBarCalendarViewModel
            )
        }
        .menuBarExtraStyle(.menu)
    }

    private func initializeAppIfNeeded() async {
        if let vaultInitializationTask {
            await vaultInitializationTask.value
            return
        }
        guard isInitializingVault else { return }
        let task = Task { @MainActor in
            await initializeApp()
        }
        vaultInitializationTask = task
        await task.value
        vaultInitializationTask = nil
    }

    private func initializeApp() async {
        guard appDatabase == nil,
              AppDelegate.hasMutationOwnership,
              let db = try? AppDatabaseManager() else {
            isInitializingVault = false
            return
        }
        appDatabase = db
        let vaultAISettings = VaultAISettingsModel.shared
        vaultAISettings.configure(dbQueue: db.dbQueue)
        await CodexRuntimeContextCoordinator.shared.configure(dbQueue: db.dbQueue)
        do {
            try await MeetingRepository(dbQueue: db.dbQueue)
                .backfillVaultAISettings(VaultAISettingsLegacyValues(settings: .shared))
            try await vaultAISettings.inheritLocalAccountSettings(from: db.dbQueue)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "vaultAISettingsBackfill"])
        }
        await DahliaCloudCredentialStorage.deleteLegacyCredential()
        await dahliaAccountController.configure(appDatabase: db)
        let meetingSyncWorker = SyncWorker(dbQueue: db.dbQueue) {
            await reconcileVaultsAfterAccountChange()
        }
        self.meetingSyncWorker = meetingSyncWorker
        await meetingSyncWorker.start(restored: {
            if case .restored = AppDelegate.backupRestoreOutcome { return true }
            return false
        }())
        do {
            try tokenBroker.start()
        } catch {
            ErrorReportingService.capture(error, context: ["source": "dahliaTokenBroker"])
        }
        await db.searchIndexer.start()
        sidebarViewModel.setAppDatabase(db)
        viewModel.configureSearchIndexer(db.searchIndexer)
        viewModel.configureBatchTranscription(dbQueue: db.dbQueue) { [weak sidebarViewModel] in
            await sidebarViewModel?.refreshUnprocessedRecordings()
        }
        appDelegate.terminationHandler = { [weak viewModel, weak db, weak tokenBroker, weak meetingSyncWorker] in
            tokenBroker?.stop()
            await meetingSyncWorker?.stop()
            await db?.searchIndexer.stop()
            return await viewModel?.prepareForTermination()
        }

        await vaultManagementModel.configure(appDatabase: db)
        let setupVersion = UserDefaults.standard.integer(forKey: SetupTourPresentationPolicy.userDefaultsKey)
        let setupProgressExists = setupVersion < SetupTourPresentationPolicy.currentVersion
            && SetupTourPresentationPolicy.hasSavedProgress()
        if !setupProgressExists,
           let vault = await vaultManagementModel.resolveExistingStartupVault(appDatabase: db) {
            openVault(vault)
        } else if SetupTourPresentationPolicy.shouldPresentAutomatically(
            storedVersion: setupVersion,
            hasLoadedVaults: vaultManagementModel.hasLoadedVaults,
            hasRegisteredVaults: !vaultManagementModel.vaults.isEmpty,
            hasSavedProgress: setupProgressExists
        ) {
            mainWindowNavigation.presentInitialSetupTour()
        }
        isInitializingVault = false
        configureMeetingDetection(in: db)
    }

    @discardableResult
    private func openVault(_ vault: VaultRecord, recordsLastOpened: Bool = true) -> Bool {
        if !showVaultPicker, AppSettings.shared.currentVault?.id == vault.id {
            AppSettings.shared.currentVault = vault
            VaultAISettingsModel.shared.activate(vault: vault)
            return true
        }
        guard viewModel.canSwitchVault, let db = appDatabase else { return false }

        if let url = vault.url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        sidebarViewModel.clearMeetingSelection()
        viewModel.clearCurrentMeeting()
        mainWindowNavigation.changeVault(to: vault.id)
        AppSettings.shared.currentVault = vault
        VaultAISettingsModel.shared.activate(vault: vault)
        chatCoordinator.activateVault(vault.id)
        sidebarViewModel.setAppDatabase(db)
        if recordsLastOpened {
            Task { await vaultManagementModel.markVaultOpened(vault) }
        }
        viewModel.prepareAnalyzer()
        showVaultPicker = false
        return true
    }

    private func signInToDahlia(_ configuration: DahliaCloudConfiguration) {
        let targetVaultID = AppSettings.shared.currentVault?.id
        guard let task = dahliaAccountController.startSignIn(configuration: configuration) else { return }
        Task { @MainActor in
            await task.value
            if dahliaAccountController.errorMessage == nil,
               let connection = dahliaAccountController.completedSignInConnection(matching: configuration) {
                if let targetVaultID,
                   let vault = vaultManagementModel.vaults.first(where: { $0.id == targetVaultID }),
                   vault.accountConnectionId == nil {
                    await vaultManagementModel.requestServerAdoption(for: vault, connection: connection)
                }
                mainWindowNavigation.dismissDahliaSignIn()
            }
        }
    }

    private func cancelDahliaSignIn() {
        dahliaAccountController.cancelAccountTask()
        mainWindowNavigation.dismissDahliaSignIn()
    }

    private func confirmServerAdoption(_ pending: PendingVaultServerAdoption) async {
        guard let updated = await vaultManagementModel.confirmServerAdoption(pending) else {
            if vaultManagementModel.pendingServerAdoption == nil {
                pendingSetupAdoptionVaultID = nil
            }
            return
        }
        await meetingSyncWorker?.drain()
        if pendingSetupAdoptionVaultID == updated.id {
            pendingSetupAdoptionVaultID = nil
            guard openVault(updated, recordsLastOpened: false),
                  await vaultManagementModel.markVaultOpened(updated)
            else { return }
            SetupTourPresentationPolicy.markCompleted()
            mainWindowNavigation.completeSetupTour()
            await dahliaAccountController.reload()
            return
        }
        if AppSettings.shared.currentVault?.id == updated.id {
            AppSettings.shared.currentVault = updated
            VaultAISettingsModel.shared.activate(vault: updated)
        }
        await dahliaAccountController.reload()
    }

    private func cancelServerAdoption() {
        pendingSetupAdoptionVaultID = nil
        vaultManagementModel.cancelServerAdoption()
    }

    private func reconcileVaultsAfterAccountChange() async {
        await vaultManagementModel.loadVaults()
        guard let current = AppSettings.shared.currentVault else { return }
        guard let updated = vaultManagementModel.vaults.first(where: { $0.id == current.id }) else {
            AppSettings.shared.currentVault = nil
            sidebarViewModel.clearMeetingSelection()
            viewModel.clearCurrentMeeting()
            showVaultPicker = true
            return
        }
        AppSettings.shared.currentVault = updated
        VaultAISettingsModel.shared.activate(vault: updated)
    }

    private func completeSetupTour(_ vault: VaultRecord, accountConnectionID: UUID?) async -> Bool {
        if let accountConnectionID, vault.accountConnectionId == nil {
            guard let connection = dahliaAccountController.connections.first(where: {
                $0.id == accountConnectionID
            }) else { return false }
            await vaultManagementModel.requestServerAdoption(for: vault, connection: connection)
            guard vaultManagementModel.pendingServerAdoption?.vault.id == vault.id else { return false }
            pendingSetupAdoptionVaultID = vault.id
            return true
        }
        guard vault.accountConnectionId == accountConnectionID,
              openVault(vault, recordsLastOpened: false),
              await vaultManagementModel.markVaultOpened(vault)
        else { return false }
        await dahliaAccountController.reload()
        SetupTourPresentationPolicy.markCompleted()
        mainWindowNavigation.completeSetupTour()
        return true
    }

    private func configureMeetingDetection(in db: AppDatabaseManager) {
        meetingDetectionService.isRecording = { [weak viewModel] in
            viewModel?.isRecordingLifecycleBusy ?? false
        }
        meetingDetectionService.isActivelyRecording = { [weak viewModel] in
            viewModel?.isListening ?? false
        }
        meetingDetectionService.onAutomaticRecording = { [weak recordingCoordinator] event in
            recordingCoordinator?.startAutomaticRecording(forCalendarEvent: event)
        }
        meetingDetectionService.onAutomaticRecordingStop = { [weak recordingCoordinator] in
            recordingCoordinator?.stopRecording()
        }
        MeetingNotificationService.shared.configure(
            onOpenMeeting: { meeting in
                handleDetectedMeeting(meeting, in: db, startTranscription: false)
            },
            onStartRecording: { meeting in
                handleDetectedMeeting(meeting, in: db, startTranscription: true)
            },
            onJoinMeeting: { [weak recordingCoordinator] meeting in
                guard let event = meeting.calendarEvent else { return }
                recordingCoordinator?.openMeetingLink(for: event)
            },
            onJoinAndStartRecording: { meeting in
                joinAndStartRecording(meeting, in: db)
            }
        )
        meetingDetectionService.start()
    }

    private func joinAndStartRecording(_ meeting: DetectedMeeting, in db: AppDatabaseManager) {
        handleDetectedMeeting(meeting, in: db, startTranscription: true)
        if let event = meeting.calendarEvent {
            recordingCoordinator.openMeetingLink(for: event)
        }
    }

    private func handleDetectedMeeting(
        _ meeting: DetectedMeeting,
        in db: AppDatabaseManager,
        startTranscription: Bool
    ) {
        guard let vault = AppSettings.shared.currentVault else { return }
        mainWindowNavigation.openMeetings()

        if let event = meeting.calendarEvent {
            let repository = MeetingRepository(dbQueue: db.dbQueue)
            do {
                if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(
                    event,
                    vaultId: vault.id,
                    customerIntelligenceIngestion: startTranscription
                        ? .afterCaptureStarts
                        : .afterMeetingPersistence
                ) {
                    sidebarViewModel.selectMeeting(existingMeetingId)
                    if startTranscription, vault.allowsCanonicalEdits {
                        startTranscriptionForMeeting(
                            existingMeetingId,
                            in: db,
                            vault: vault,
                            customerIntelligenceEvent: event
                        )
                    }
                    return
                }
            } catch {
                viewModel.errorMessage = error.localizedDescription
                ErrorReportingService.capture(error, context: ["source": "calendarMeetingResolution"])
                return
            }

            guard vault.allowsCanonicalEdits else { return }
            sidebarViewModel.clearMeetingSelection()
            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: db.dbQueue,
                vaultURL: vault.url
            )
            guard let meetingId = viewModel.materializeDraftMeeting(
                customerIntelligenceIngestion: startTranscription
                    ? .afterCaptureStarts
                    : .afterMeetingPersistence
            ) else { return }
            sidebarViewModel.selectMeeting(meetingId)
            if startTranscription {
                startTranscriptionForMeeting(
                    meetingId,
                    in: db,
                    vault: vault,
                    customerIntelligenceEvent: event
                )
            }
            return
        }

        guard vault.allowsCanonicalEdits else { return }
        guard let meetingId = viewModel.createEmptyMeeting(
            dbQueue: db.dbQueue,
            projectURL: nil,
            vaultId: vault.id,
            projectId: nil,
            name: "",
            projectName: nil,
            vaultURL: vault.url
        ) else { return }
        sidebarViewModel.selectMeeting(meetingId)
        if startTranscription {
            startTranscriptionForMeeting(meetingId, in: db, vault: vault)
        }
    }

    private func startTranscriptionForMeeting(
        _ meetingId: UUID,
        in db: AppDatabaseManager,
        vault: VaultRecord,
        customerIntelligenceEvent: CalendarEvent? = nil
    ) {
        let ctx: (projectURL: URL?, projectId: UUID?, projectName: String?)
        do {
            ctx = try meetingContext(for: meetingId, in: db, vault: vault)
        } catch {
            viewModel.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "meetingContext"])
            return
        }
        guard let reservation = viewModel.reserveRecordingStart() else { return }
        Task { @MainActor in
            await viewModel.startListening(
                dbQueue: db.dbQueue,
                projectURL: ctx.projectURL,
                vaultId: vault.id,
                projectId: ctx.projectId,
                projectName: ctx.projectName,
                vaultURL: vault.url,
                appendingTo: meetingId,
                reservation: reservation
            )
            recordingCoordinator.recordingDidStart()
            if let customerIntelligenceEvent,
               viewModel.isListening,
               viewModel.recordingMeetingId == meetingId {
                CustomerIntelligenceIngestionService.schedule(
                    calendarEvent: customerIntelligenceEvent,
                    meetingId: meetingId,
                    vaultId: vault.id,
                    observedAt: .now,
                    dbQueue: db.dbQueue
                )
            }
        }
    }

    private func meetingContext(
        for meetingId: UUID,
        in db: AppDatabaseManager,
        vault: VaultRecord
    ) throws -> (projectURL: URL?, projectId: UUID?, projectName: String?) {
        let repository = MeetingRepository(dbQueue: db.dbQueue)
        guard let meeting = try repository.fetchMeeting(id: meetingId) else {
            return (nil, nil, nil)
        }
        let project = try meeting.projectId.flatMap { try repository.fetchProject(id: $0) }
        let projectURL = project.flatMap { project in
            vault.url?.appending(path: project.path, directoryHint: .isDirectory)
        }
        return (projectURL, project?.id, project?.path)
    }
}

private struct MainWindowOpenWindowRegistrationModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            MainWindowOpener.shared.register(openWindow: openWindow)
        }
    }
}

private extension Scene {
    func dahliaSettingsCommands(_ navigation: MainWindowNavigation) -> some Scene {
        commands {
            SettingsCommands(mainWindowNavigation: navigation)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private(set) static var hasMutationOwnership = false
    @MainActor private(set) static var backupRestoreOutcome: BackupRestoreStartupOutcome = .none
    @MainActor private(set) static var isBackupRestorePreparationActive = false

    @MainActor
    static func beginBackupRestorePreparation() -> Bool {
        guard !isBackupRestorePreparationActive else { return false }
        isBackupRestorePreparationActive = true
        return true
    }

    @MainActor
    static func cancelBackupRestorePreparation() {
        isBackupRestorePreparationActive = false
    }

    private var isWaitingForCodexShutdown = false
    private var processLock: AdvisoryFileLock?
    @MainActor var terminationHandler: (@MainActor () async -> String?)?

    func applicationWillFinishLaunching(_: Notification) {
        do {
            processLock = try AdvisoryFileLock.acquire(
                at: AppDatabaseManager.databaseURL
                    .deletingLastPathComponent()
                    .appending(path: ".process.lock")
            )
            Self.hasMutationOwnership = true
            Self.backupRestoreOutcome = BackupRestoreStartupProcessor.applyPendingRestore()
        } catch AdvisoryFileLockError.alreadyLocked {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.anotherDahliaInstanceTitle
            alert.informativeText = L10n.anotherDahliaInstanceMessage
            alert.runModal()
            NSApplication.shared.terminate(nil)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard Self.hasMutationOwnership else { return }
        MeetingNotificationService.shared.install()
        ErrorReportingService.start()
        UsageTelemetryService.shared.start()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task {
            // Connection errors are surfaced by the AI settings and summary actions.
            try? await CodexAppServerService.shared.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isWaitingForCodexShutdown else { return .terminateLater }
        isWaitingForCodexShutdown = true
        Task {
            if let failureMessage = await terminationHandler?() {
                isWaitingForCodexShutdown = false
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.terminationPersistenceFailedTitle
                alert.informativeText = failureMessage
                alert.runModal()
                return
            }
            await CodexAppServerService.shared.shutdown()
            await CodexAppServerService.localAccount.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowOpener.shared.openMainWindow()
        }
        return true
    }
}
