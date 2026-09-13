#if canImport(Testing)
    import AppKit
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct SetupTourTests {
        @Test
        func selectsDiscoveredWorkspaceWithoutCreatingALocalWorkspace() throws {
            let suiteName = "SetupDiscoveredWorkspace-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let connectionID = UUID.v7()
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            model.selectAccountConnection(connectionID)
            model.advance()
            var workspace = WorkspaceRecord(id: .v7(), name: "Shared", createdAt: .now, lastOpenedAt: .distantPast)
            workspace.accountConnectionId = connectionID
            workspace.organizationId = workspace.accountConnectionId == nil ? nil : (workspace.organizationId ?? .v7())
            model.selectExistingWorkspace(workspace)
            #expect(model.selectedExistingWorkspaceID == workspace.id)
            #expect(model.canContinue)
            #expect(model.selectedWorkspaceName == nil)
            #expect(!model.keepsOriginalWorkspace)
            model.advance()
            let restored = SetupTourModel(
                mode: .initial,
                currentWorkspace: nil,
                signedInAccountConnectionIDs: [connectionID],
                progressDefaults: defaults
            )
            #expect(restored.currentStep == .workspace)
            #expect(!restored.isWorkspaceLocationConfirmed)
            model.selectAccountConnection(nil)
            #expect(model.selectedExistingWorkspaceID == nil)
            #expect(!model.isWorkspaceLocationConfirmed)
        }

        @Test
        func automaticPresentationIsLimitedToNewUsers() {
            #expect(SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: 0,
                hasLoadedWorkspaces: true,
                hasRegisteredWorkspaces: false
            ))
            #expect(!SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: 0,
                hasLoadedWorkspaces: true,
                hasRegisteredWorkspaces: true
            ))
            #expect(!SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: SetupTourPresentationPolicy.currentVersion,
                hasLoadedWorkspaces: true,
                hasRegisteredWorkspaces: false
            ))
            #expect(!SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: 0,
                hasLoadedWorkspaces: false,
                hasRegisteredWorkspaces: false
            ))
            #expect(SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: 0,
                hasLoadedWorkspaces: true,
                hasRegisteredWorkspaces: true,
                hasSavedProgress: true
            ))
        }

        @Test
        func completionStoresTheCurrentPresentationVersion() throws {
            let suiteName = "SetupTourTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            SetupTourPresentationPolicy.saveProgress(
                step: .modelProvider,
                workspaceURL: URL(filePath: "/tmp/Dahlia", directoryHint: .isDirectory),
                isWorkspaceConfirmed: true,
                in: defaults
            )

            SetupTourPresentationPolicy.markCompleted(in: defaults)

            #expect(defaults.integer(forKey: SetupTourPresentationPolicy.userDefaultsKey) ==
                SetupTourPresentationPolicy.currentVersion)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.progressStepUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.workspacePathUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.workspaceNameUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.workspaceConfirmedUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.providerUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.databricksProfileUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.accountConnectionIDUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.accountSelectionConfirmedUserDefaultsKey) == nil)
        }

        @Test
        func interruptedInitialTourRestoresItsProviderDraft() throws {
            let suiteName = "SetupTourProviderProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            SetupTourPresentationPolicy.saveProgress(
                step: .modelProvider,
                workspaceURL: URL(filePath: "/tmp/Dahlia", directoryHint: .isDirectory),
                isWorkspaceConfirmed: true,
                in: defaults
            )
            let draft = WorkspaceAISettingsModel(setupDefaults: defaults)
            draft.localProvider = .databricks
            draft.databricksProfile = "setup-profile"

            let restored = WorkspaceAISettingsModel(setupDefaults: defaults)

            #expect(restored.localProvider == .databricks)
            #expect(restored.databricksProfile == "setup-profile")
        }

        @Test
        func interruptedInitialTourRestoresItsStepAndWorkspace() throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let selectedURL = URL(filePath: "/tmp/Selected Dahlia", directoryHint: .isDirectory)
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)

            model.selectAccountConnection(nil)
            model.advance()
            model.selectWorkspaceURL(selectedURL)
            model.confirmWorkspaceSelection()
            model.advance()

            let restoredModel = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            #expect(restoredModel.currentStep == .workingLanguages)
            #expect(restoredModel.selectedWorkspaceURL == selectedURL)
            #expect(restoredModel.isWorkspaceLocationConfirmed)
        }

        @Test
        func interruptedInitialTourRestoresItsDahliaAccount() throws {
            let suiteName = "SetupTourAccountProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let connectionID = UUID.v7()
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)

            model.selectAccountConnection(connectionID)
            model.advance()

            let signedOutRestoredModel = SetupTourModel(
                mode: .initial,
                currentWorkspace: nil,
                progressDefaults: defaults
            )
            let restoredModel = SetupTourModel(
                mode: .initial,
                currentWorkspace: nil,
                signedInAccountConnectionIDs: [connectionID],
                progressDefaults: defaults
            )

            #expect(signedOutRestoredModel.currentStep == .account)
            #expect(!signedOutRestoredModel.isAccountSelectionConfirmed)
            #expect(restoredModel.currentStep == .workspace)
            #expect(restoredModel.selectedAccountConnectionID == connectionID)
            #expect(restoredModel.isAccountSelectionConfirmed)
            #expect(!restoredModel.visibleSteps.contains(.modelProvider))
        }

        @Test
        func incompleteWorkspaceProgressReturnsToWorkspaceConfirmation() throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(SetupTourStep.modelProvider.rawValue, forKey: SetupTourPresentationPolicy.progressStepUserDefaultsKey)
            defaults.set(true, forKey: SetupTourPresentationPolicy.accountSelectionConfirmedUserDefaultsKey)

            let restoredModel = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)

            #expect(restoredModel.currentStep == .workspace)
            #expect(!restoredModel.isWorkspaceLocationConfirmed)
        }

        @Test
        func workspaceStepRequiresExplicitConfirmationBeforeAdvancing() {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)

            model.selectAccountConnection(nil)
            model.advance()

            #expect(model.currentStep == .workspace)
            #expect(!model.isWorkspaceLocationConfirmed)
            #expect(!model.canContinue)

            model.advance()
            #expect(model.currentStep == .workspace)

            model.confirmWorkspaceSelection()
            model.advance()

            #expect(model.currentStep == .workingLanguages)
            #expect(model.isWorkspaceLocationConfirmed)
        }

        @Test
        func pathlessCurrentWorkspaceIsKeptUntilAnotherLocationIsSelected() {
            let workspace = WorkspaceRecord(
                id: .v7(), path: nil, name: "Cloud Workspace",
                createdAt: .now, lastOpenedAt: .now
            )
            let model = SetupTourModel(mode: .manual, currentWorkspace: workspace)

            #expect(model.keepsOriginalWorkspace)
            model.selectWorkspaceURL(URL(filePath: "/tmp/Export", directoryHint: .isDirectory))
            model.confirmWorkspaceSelection()
            #expect(!model.keepsOriginalWorkspace)
        }

        @Test
        func pathlessWorkspaceSelectionSurvivesInterruptedInitialTour() throws {
            let suiteName = "SetupTourPathlessProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            model.selectAccountConnection(nil)
            model.advance()
            model.selectPathlessWorkspace(named: "Cloud Workspace")
            model.advance()

            let restored = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            #expect(restored.selectedWorkspaceName == "Cloud Workspace")
            #expect(restored.isWorkspaceLocationConfirmed)
        }

        @Test
        func setupUsesTheRequestedConfigurationOrder() {
            #expect(SetupTourStep.allCases == [
                .account,
                .workspace,
                .workingLanguages,
                .permissions,
                .modelProvider,
                .calendar,
                .completion,
            ])
            #expect(SetupTourModel(mode: .initial, currentWorkspace: nil).currentStep == .account)
        }

        @Test
        func backNavigationStartsAfterTheFirstStep() {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)

            #expect(!model.canGoBack)
            model.selectAccountConnection(nil)
            model.advance()
            model.confirmWorkspaceSelection()
            model.advance()
            #expect(model.currentStep == .workingLanguages)
            #expect(model.canGoBack)
        }

        @Test
        func navigationMovesSequentiallyAndNeverPastCompletion() {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            model.selectAccountConnection(nil)
            model.advance()
            model.confirmWorkspaceSelection()
            model.advance()
            model.advance()
            model.advance()
            model.advance()
            #expect(model.currentStep == .calendar)
            #expect(model.canContinue)
            model.advance()

            #expect(model.currentStep == .completion)

            model.advance()
            #expect(model.currentStep == .completion)

            model.goBack()
            #expect(model.currentStep == .calendar)

            model.returnToStep(.workingLanguages)
            #expect(model.currentStep == .workingLanguages)
            model.returnToStep(.completion)
            #expect(model.currentStep == .workingLanguages)
        }

        @Test
        func dahliaAccountSkipsLocalModelProviderSetup() {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            let connectionID = UUID.v7()

            model.selectAccountConnection(connectionID)
            model.advance()
            model.confirmWorkspaceSelection()
            model.advance()
            model.advance()
            model.advance()

            #expect(model.selectedAccountConnectionID == connectionID)
            #expect(!model.visibleSteps.contains(.modelProvider))
            #expect(model.currentStep == .calendar)
        }

        @Test
        func savedProgressIsDetectedIndependentlyOfItsStep() throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            #expect(!SetupTourPresentationPolicy.hasSavedProgress(in: defaults))
            SetupTourPresentationPolicy.saveProgress(
                step: .completion,
                workspaceURL: URL(filePath: "/tmp/Dahlia", directoryHint: .isDirectory),
                isWorkspaceConfirmed: true,
                in: defaults
            )
            #expect(SetupTourPresentationPolicy.hasSavedProgress(in: defaults))
        }

        @Test
        func selectingAnotherWorkspaceRequiresASecondConfirmation() {
            let currentWorkspace = WorkspaceRecord(
                id: .v7(),
                path: "/tmp/Current",
                name: "Current",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let model = SetupTourModel(mode: .manual, currentWorkspace: currentWorkspace)

            #expect(model.isWorkspaceLocationConfirmed)
            #expect(model.currentStep == .account)
            model.advance()
            #expect(model.currentStep == .workspace)
            #expect(model.canContinue)

            model.selectWorkspaceURL(URL(filePath: "/tmp/Other", directoryHint: .isDirectory))

            #expect(!model.isWorkspaceLocationConfirmed)
            #expect(model.currentStep == .workspace)
            #expect(!model.canContinue)
        }

        @Test
        func signedOutWorkspaceAccountRequiresReauthentication() {
            let connectionID = UUID.v7()
            let currentWorkspace = WorkspaceRecord(
                id: .v7(),
                path: "/tmp/Current",
                name: "Current",
                createdAt: .now,
                lastOpenedAt: .now,
                accountConnectionId: connectionID
            )
            let signedOutModel = SetupTourModel(mode: .manual, currentWorkspace: currentWorkspace)
            let signedInModel = SetupTourModel(
                mode: .manual,
                currentWorkspace: currentWorkspace,
                signedInAccountConnectionIDs: [connectionID]
            )

            #expect(signedOutModel.selectedAccountConnectionID == connectionID)
            #expect(!signedOutModel.isAccountSelectionConfirmed)
            #expect(!signedOutModel.canContinue)
            signedOutModel.advance()
            #expect(signedOutModel.currentStep == .account)

            #expect(signedInModel.isAccountSelectionConfirmed)
            #expect(signedInModel.canContinue)
        }

        @Test
        func setupRequestsOnlyAudioPermissions() {
            #expect(PermissionSetupStepView.permissions == [.screenAndSystemAudio, .microphone])
            #expect(!PermissionSetupStepView.permissions.contains(.calendar))
        }

        @Test
        func setupNormalizesCalendarSelectionToOneSource() {
            #expect(CalendarSettingsView.exclusiveSetupSource(from: [.macOS]) == .macOS)
            #expect(CalendarSettingsView.exclusiveSetupSource(from: [.google]) == .google)
            #expect(CalendarSettingsView.exclusiveSetupSource(from: [.macOS, .google]) == .google)
            #expect(CalendarSettingsView.exclusiveSetupSource(from: []) == .google)
        }

        @Test
        func providerLogosAreBundledAndLoadable() throws {
            for name in ["ProviderOpenAI", "ProviderDatabricks"] {
                let url = try #require(Bundle.appModule.url(forResource: name, withExtension: "svg"))
                #expect(NSImage(contentsOf: url) != nil)
            }
        }

        @Test
        func googleCalendarLogoIsBundledAndLoadable() throws {
            let url = try #require(Bundle.appModule.url(forResource: "GoogleCalendar", withExtension: "png"))
            #expect(NSImage(contentsOf: url) != nil)
        }

        @Test
        func manualTourReturnsToGeneralSettings() throws {
            let suiteName = "SetupTourNavigationTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let navigation = MainWindowNavigation(
                openMainWindow: {},
                openMainWindowWithoutActivation: {},
                initialSettingsCategory: .general,
                settingsDefaults: defaults
            )

            navigation.openSetupTour()
            #expect(navigation.setupTourMode == .manual)
            #expect(!navigation.isShowingSettings)

            navigation.dismissSetupTour()
            #expect(navigation.setupTourMode == nil)
            #expect(navigation.isShowingSettings)
            #expect(navigation.settingsCategory == .general)
        }

        @Test
        func initialTourCannotBeDismissed() throws {
            let suiteName = "SetupTourNavigationTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let navigation = MainWindowNavigation(
                openMainWindow: {},
                openMainWindowWithoutActivation: {},
                settingsDefaults: defaults
            )

            navigation.presentInitialSetupTour()
            navigation.dismissSetupTour()

            #expect(navigation.setupTourMode == .initial)
            #expect(!navigation.isShowingSettings)
        }
    }
#endif
