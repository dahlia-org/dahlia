#if canImport(Testing)
    import AppKit
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct SetupTourTests {
        @Test
        func piCheckBlocksTheFirstStepUntilItFinishes() async {
            let model = SetupTourModel(mode: .manual, currentWorkspace: nil)
            #expect(model.isCheckingPi)
            #expect(!model.canContinue)
            #expect(!model.canGoBack)
            model.advance()
            #expect(model.currentStep == .modelProvider)

            await model.checkPi { true }
            #expect(!model.isCheckingPi)
            #expect(model.canContinue)
            #expect(model.currentStep == .modelProvider)
            #expect(!model.visibleSteps.contains(.pi))
        }

        @Test
        func missingPiIsOfferedBeforeProviders() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            await model.checkPi { false }
            #expect(model.currentStep == .pi)
            #expect(model.visibleSteps.prefix(2) == [.pi, .modelProvider])
            #expect(!model.canGoBack)
            model.advance()
            #expect(model.currentStep == .modelProvider)
            model.goBack()
            #expect(model.currentStep == .pi)
        }

        @Test
        func workspacePreparationDoesNotInvalidatePiDetection() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            await model.checkPi {
                _ = await model.prepareInitialWorkspace { nil }
                return false
            }
            #expect(model.currentStep == .pi)
        }

        @Test
        func cancelledPiDetectionRunsAgain() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            let task = Task {
                await model.checkPi {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return false
                }
            }
            await task.value
            #expect(model.isCheckingPi)
            #expect(model.currentStep == .modelProvider)
            await model.checkPi { false }
            #expect(model.currentStep == .pi)
        }

        @Test
        func interruptedPiSetupRestoresItsStep() async throws {
            let suiteName = "SetupPiProgress-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            await model.checkPi { false }
            let restored = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            #expect(restored.currentStep == .pi)
            #expect(!restored.isCheckingPi)
            #expect(restored.visibleSteps.contains(.pi))
            restored.advance()
            #expect(restored.currentStep == .modelProvider)
        }

        @Test(arguments: [0, 6])
        func removedWorkspaceAndAccountStepsRestartTheTour(savedStep: Int) throws {
            let suiteName = "SetupRemovedStep-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(savedStep, forKey: SetupTourPresentationPolicy.progressStepUserDefaultsKey)
            defaults.set(true, forKey: SetupTourPresentationPolicy.accountSelectionConfirmedUserDefaultsKey)

            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)

            #expect(model.currentStep == .modelProvider)
            #expect(model.isCheckingPi)
        }

        @Test
        func preparationCanRetryWithoutBlockingOtherSteps() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            await model.checkPi { true }
            model.advance()
            #expect(await model.prepareInitialWorkspace { nil } == nil)
            #expect(model.canContinue)
            #expect(!model.isPreparingWorkspace)
            let workspace = WorkspaceRecord(id: .v7(), name: "Local", createdAt: .now, lastOpenedAt: .distantPast)
            #expect(await model.prepareInitialWorkspace { workspace }?.id == workspace.id)
        }

        @Test
        func automaticPresentationIsLimitedToMissingWorkspacesOrUnfinishedSetup() {
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
            #expect(SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: SetupTourPresentationPolicy.currentVersion,
                hasLoadedWorkspaces: true,
                hasRegisteredWorkspaces: false
            ))
            #expect(!SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: SetupTourPresentationPolicy.currentVersion,
                hasLoadedWorkspaces: true,
                hasRegisteredWorkspaces: true,
                hasSavedProgress: true
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
            SetupTourPresentationPolicy.saveProgress(step: .modelProvider, in: defaults)
            defaults.set(UUID.v7().uuidString, forKey: SetupTourPresentationPolicy.databricksConnectionIDUserDefaultsKey)
            defaults.set(true, forKey: SetupTourPresentationPolicy.accountSelectionConfirmedUserDefaultsKey)

            SetupTourPresentationPolicy.markCompleted(in: defaults)

            #expect(defaults.integer(forKey: SetupTourPresentationPolicy.userDefaultsKey) ==
                SetupTourPresentationPolicy.currentVersion)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.progressStepUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.providerUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.databricksProfileUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.accountConnectionIDUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.databricksConnectionIDUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.modelProviderFirstUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.accountSelectionConfirmedUserDefaultsKey) == nil)
        }

        @Test
        func interruptedInitialTourRestoresItsProviderDraft() throws {
            let suiteName = "SetupTourProviderProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            SetupTourPresentationPolicy.saveProgress(step: .modelProvider, in: defaults)
            let draft = WorkspaceAISettingsModel(setupDefaults: defaults)
            draft.localProvider = .databricks
            draft.databricksProfile = "setup-profile"

            let restored = WorkspaceAISettingsModel(setupDefaults: defaults)

            #expect(restored.localProvider == .databricks)
            #expect(restored.databricksProfile == "setup-profile")
        }

        @Test
        func interruptedInitialTourRestoresItsStep() async throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)

            await model.checkPi { true }
            model.advance()

            let restoredModel = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            #expect(restoredModel.currentStep == .workingLanguages)
            #expect(!restoredModel.isCheckingPi)
        }

        @Test
        func progressFromTheEarlierStepOrderResumesAtTheModelProviderStep() throws {
            let suiteName = "SetupTourLegacyOrderTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            // v0.29.0 saved these keys and asked for model providers after permissions.
            defaults.set(SetupTourStep.permissions.rawValue, forKey: SetupTourPresentationPolicy.progressStepUserDefaultsKey)
            defaults.set(true, forKey: SetupTourPresentationPolicy.accountSelectionConfirmedUserDefaultsKey)

            let local = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            #expect(local.currentStep == .modelProvider)

            SetupTourPresentationPolicy.saveProgress(step: .permissions, in: defaults)
            let current = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            #expect(current.currentStep == .permissions)
        }

        @Test
        func savedModelProviderStepIsRestoredForTheLocalAccount() throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(SetupTourStep.modelProvider.rawValue, forKey: SetupTourPresentationPolicy.progressStepUserDefaultsKey)
            defaults.set(true, forKey: SetupTourPresentationPolicy.accountSelectionConfirmedUserDefaultsKey)

            let restoredModel = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)

            #expect(restoredModel.currentStep == .modelProvider)
        }

        @Test
        func modelProvidersComeFirstAndMayBeSkipped() async {
            for mode in [SetupTourMode.initial, .manual] {
                let model = SetupTourModel(mode: mode, currentWorkspace: nil)
                await model.checkPi { true }

                #expect(model.currentStep == .modelProvider)
                #expect(model.canContinue)
                model.advance()
                #expect(model.currentStep == .workingLanguages)
            }
        }

        @Test
        func manualTourKeepsTheOpenWorkspace() {
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Default", createdAt: .now, lastOpenedAt: .now)
            let model = SetupTourModel(mode: .manual, currentWorkspace: workspace)

            #expect(model.keepsOriginalWorkspace)
        }

        @Test
        func setupUsesTheRequestedConfigurationOrder() {
            #expect(SetupTourStep.allCases == [
                .pi,
                .modelProvider,
                .workingLanguages,
                .permissions,
                .calendar,
                .completion,
            ])
            #expect(SetupTourModel(mode: .initial, currentWorkspace: nil).currentStep == .modelProvider)
        }

        @Test
        func backNavigationStartsAfterTheFirstStep() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            await model.checkPi { true }

            #expect(!model.canGoBack)
            model.advance()
            #expect(model.currentStep == .workingLanguages)
            #expect(model.canGoBack)
        }

        @Test
        func navigationMovesSequentiallyAndNeverPastCompletion() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            await model.checkPi { true }
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
        func savedProgressIsDetectedIndependentlyOfItsStep() throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            #expect(!SetupTourPresentationPolicy.hasSavedProgress(in: defaults))
            SetupTourPresentationPolicy.saveProgress(step: .completion, in: defaults)
            #expect(SetupTourPresentationPolicy.hasSavedProgress(in: defaults))
        }

        @Test
        func setupRequestsOnlyAudioPermissions() {
            #expect(PermissionSetupStepView.permissions == [.screenAndSystemAudio, .microphone])
            #expect(!PermissionSetupStepView.permissions.contains(.calendar))
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
