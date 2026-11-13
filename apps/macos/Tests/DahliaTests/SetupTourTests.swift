#if canImport(Testing)
    import AppKit
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct SetupTourTests {
        @Test
        func pendingAccountSetupBlocksTourNavigationAndDismissal() async {
            let workspace = WorkspaceRecord(
                id: .v7(), path: nil, name: "Existing", createdAt: .now, lastOpenedAt: .now
            )
            let model = SetupTourModel(mode: .manual, currentWorkspace: workspace)
            #expect(model.canContinue)
            #expect(model.canDismiss)

            model.isAccountSetupInProgress = true
            #expect(!model.canContinue)
            #expect(!model.canDismiss)
            model.advance()
            await model.advanceFromAccount { _ in
                Issue.record("Pending workspace choice must not advance the original account")
                return true
            }
            #expect(model.currentStep == .account)
            #expect(model.selectedDatabricksConnectionID == nil)

            // Explicit cancellation releases the original account without changing it.
            model.isAccountSetupInProgress = false
            #expect(model.canContinue)
            #expect(model.canDismiss)
            #expect(model.selectedDatabricksConnectionID == nil)

            // Explicit completion releases the lock before advancing with the chosen account.
            model.isAccountSetupInProgress = true
            let connectionID = UUID.v7()
            model.selectAccountConnection(nil, databricks: connectionID)
            #expect(!model.canContinue)
            model.isAccountSetupInProgress = false
            await model.advanceFromAccount { account in
                #expect(account == .databricks(connectionID: connectionID))
                return true
            }
            #expect(model.currentStep == .workingLanguages)
            #expect(model.selectedDatabricksConnectionID == connectionID)
        }

        @Test
        func missingPiIsOfferedBeforeProvidersForEveryAccount() async {
            for account in [CodexRuntimeProvider.local, .databricks(connectionID: .v7()), .dahlia(connectionID: .v7())] {
                let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
                if case let .databricks(connectionID) = account {
                    model.selectAccountConnection(nil, databricks: connectionID)
                } else {
                    model.selectAccountConnection(account.accountConnectionID)
                }
                await model.advanceFromAccount { selected in
                    #expect(selected == account)
                    #expect(model.isCheckingPi)
                    #expect(!model.canContinue)
                    return false
                }
                #expect(model.currentStep == .pi)
                #expect(model.visibleSteps.prefix(2) == [.account, .pi])
                #expect(model.canContinue)
                model.advance()
                #expect(model.currentStep == (account == .local ? .modelProvider : .workingLanguages))
                model.goBack()
                #expect(model.currentStep == .pi)
            }
        }

        @Test
        func availablePiSkipsInstallationForEveryAccount() async {
            for account in [CodexRuntimeProvider.local, .databricks(connectionID: .v7()), .dahlia(connectionID: .v7())] {
                let model = SetupTourModel(mode: .manual, currentWorkspace: nil)
                if case let .databricks(connectionID) = account {
                    model.selectAccountConnection(nil, databricks: connectionID)
                } else {
                    model.selectAccountConnection(account.accountConnectionID)
                }
                await model.advanceFromAccount { _ in true }
                #expect(!model.visibleSteps.contains(.pi))
                #expect(model.currentStep == (account == .local ? .modelProvider : .workingLanguages))
            }
        }

        @Test
        func piCheckRejectsAnAccountChangedWhileChecking() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            model.selectAccountConnection(nil)
            await model.advanceFromAccount { _ in
                model.selectAccountConnection(nil, databricks: .v7())
                return false
            }
            #expect(model.currentStep == .account)
            #expect(!model.isCheckingPi)
            await model.advanceFromAccount { _ in false }
            #expect(model.currentStep == .pi)
        }

        @Test
        func workspacePreparationDoesNotInvalidatePiDetection() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            model.selectAccountConnection(nil)
            await model.advanceFromAccount { _ in
                _ = await model.prepareInitialWorkspace { nil }
                return false
            }
            #expect(model.currentStep == .pi)
        }

        @Test
        func cancelledPiDetectionStaysOnAccountSelection() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            model.selectAccountConnection(nil)
            let task = Task {
                await model.advanceFromAccount { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return false
                }
            }
            await task.value
            #expect(model.currentStep == .account)
            #expect(!model.isCheckingPi)
        }

        @Test
        func interruptedPiSetupRestoresItsStep() async throws {
            let suiteName = "SetupPiProgress-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            model.selectAccountConnection(nil)
            await model.advanceFromAccount { _ in false }
            let restored = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            #expect(restored.currentStep == .pi)
            #expect(restored.visibleSteps.contains(.pi))
            restored.advance()
            #expect(restored.currentStep == .modelProvider)
        }

        @Test
        func interruptedInitialTourRestoresItsDatabricksAccount() throws {
            let suiteName = "SetupDatabricksProgress-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let databricksID = UUID.v7()
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            model.selectAccountConnection(nil, databricks: databricksID)
            model.advance()
            #expect(model.currentStep == .workingLanguages)

            let restored = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            #expect(restored.currentStep == .workingLanguages)
            #expect(restored.selectedDatabricksConnectionID == databricksID)
            #expect(restored.selectedAccountConnectionID == nil)
            #expect(!restored.visibleSteps.contains(.modelProvider))
        }

        @Test
        func legacyWorkspaceStepRestoresAsAccountSelection() throws {
            let suiteName = "SetupLegacyWorkspaceStep-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(0, forKey: SetupTourPresentationPolicy.progressStepUserDefaultsKey)
            defaults.set(true, forKey: SetupTourPresentationPolicy.accountSelectionConfirmedUserDefaultsKey)

            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)

            #expect(model.currentStep == .account)
            #expect(model.canContinue)
        }

        @Test
        func preparationCanRetryWithoutBlockingOtherSteps() async {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            model.selectAccountConnection(nil)
            model.advance()
            #expect(await model.prepareInitialWorkspace { nil } == nil)
            #expect(model.canContinue)
            #expect(!model.isPreparingWorkspace)
            let workspace = WorkspaceRecord(id: .v7(), name: "Local", createdAt: .now, lastOpenedAt: .distantPast)
            #expect(await model.prepareInitialWorkspace { workspace }?.id == workspace.id)
        }

        @Test
        func accountChangeDiscardsDelayedWorkspacePreparation() async throws {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            let connectionID = UUID.v7()
            model.selectAccountConnection(connectionID)
            var remote = WorkspaceRecord(id: .v7(), name: "Personal", createdAt: .now, lastOpenedAt: .distantPast)
            remote.accountConnectionId = connectionID
            var finish: CheckedContinuation<WorkspaceRecord?, Never>?
            var preparing: Task<WorkspaceRecord?, Never>?
            await withCheckedContinuation { started in
                preparing = Task {
                    await model.prepareInitialWorkspace {
                        await withCheckedContinuation {
                            finish = $0
                            started.resume()
                        }
                    }
                }
            }
            #expect(model.isPreparingWorkspace)
            #expect(model.canContinue)
            model.selectAccountConnection(nil)
            // Returning to the same account must still reject the earlier generation.
            model.selectAccountConnection(connectionID)
            try #require(finish).resume(returning: remote)
            let result = await preparing?.value
            #expect(result == nil)
            #expect(!model.isPreparingWorkspace)
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
            SetupTourPresentationPolicy.saveProgress(
                step: .modelProvider,
                databricksConnectionID: .v7(),
                isAccountSelectionConfirmed: true,
                in: defaults
            )

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
        func interruptedInitialTourRestoresItsStep() throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)

            model.selectAccountConnection(nil)
            model.advance()
            model.advance()

            let restoredModel = SetupTourModel(mode: .initial, currentWorkspace: nil, progressDefaults: defaults)
            #expect(restoredModel.currentStep == .workingLanguages)
            #expect(restoredModel.isAccountSelectionConfirmed)
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
            #expect(restoredModel.currentStep == .workingLanguages)
            #expect(restoredModel.selectedAccountConnectionID == connectionID)
            #expect(restoredModel.isAccountSelectionConfirmed)
            #expect(!restoredModel.visibleSteps.contains(.modelProvider))
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

            let connectionID = UUID.v7()
            defaults.set(connectionID.uuidString, forKey: SetupTourPresentationPolicy.accountConnectionIDUserDefaultsKey)
            let dahlia = SetupTourModel(
                mode: .initial,
                currentWorkspace: nil,
                signedInAccountConnectionIDs: [connectionID],
                progressDefaults: defaults
            )
            #expect(dahlia.currentStep == .permissions)

            SetupTourPresentationPolicy.saveProgress(step: .permissions, isAccountSelectionConfirmed: true, in: defaults)
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
        func localAccountSetsUpModelProvidersFirstAndMaySkipThem() {
            for mode in [SetupTourMode.initial, .manual] {
                let model = SetupTourModel(mode: mode, currentWorkspace: nil)

                model.selectAccountConnection(nil)
                model.advance()

                #expect(model.currentStep == .modelProvider)
                #expect(model.canContinue)
                model.advance()
                #expect(model.currentStep == .workingLanguages)
            }
        }

        @Test
        func manualTourKeepsTheOpenWorkspaceOfTheSelectedAccount() {
            let workspace = WorkspaceRecord(
                id: .v7(), path: nil, name: "Cloud Workspace",
                createdAt: .now, lastOpenedAt: .now
            )
            let model = SetupTourModel(mode: .manual, currentWorkspace: workspace)

            #expect(model.keepsOriginalWorkspace)
            model.selectAccountConnection(nil)
            #expect(model.keepsOriginalWorkspace)
        }

        @Test
        func choosingADatabricksAccountDoesNotKeepTheLocalWorkspace() {
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Default", createdAt: .now, lastOpenedAt: .now)
            let model = SetupTourModel(mode: .manual, currentWorkspace: workspace)

            model.selectAccountConnection(nil, databricks: .v7())

            #expect(!model.keepsOriginalWorkspace)
        }

        @Test
        func setupUsesTheRequestedConfigurationOrder() {
            #expect(SetupTourStep.allCases == [
                .account,
                .pi,
                .modelProvider,
                .workingLanguages,
                .permissions,
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
            #expect(model.currentStep == .modelProvider)
            #expect(model.canGoBack)
        }

        @Test
        func navigationMovesSequentiallyAndNeverPastCompletion() {
            let model = SetupTourModel(mode: .initial, currentWorkspace: nil)
            model.selectAccountConnection(nil)
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
            SetupTourPresentationPolicy.saveProgress(step: .completion, in: defaults)
            #expect(SetupTourPresentationPolicy.hasSavedProgress(in: defaults))
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
