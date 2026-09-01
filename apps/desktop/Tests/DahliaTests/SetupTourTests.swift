#if canImport(Testing)
    import AppKit
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct SetupTourTests {
        @Test
        func automaticPresentationIsLimitedToNewUsers() {
            #expect(SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: 0,
                hasLoadedVaults: true,
                hasRegisteredVaults: false
            ))
            #expect(!SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: 0,
                hasLoadedVaults: true,
                hasRegisteredVaults: true
            ))
            #expect(!SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: SetupTourPresentationPolicy.currentVersion,
                hasLoadedVaults: true,
                hasRegisteredVaults: false
            ))
            #expect(!SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: 0,
                hasLoadedVaults: false,
                hasRegisteredVaults: false
            ))
            #expect(SetupTourPresentationPolicy.shouldPresentAutomatically(
                storedVersion: 0,
                hasLoadedVaults: true,
                hasRegisteredVaults: true,
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
                vaultURL: URL(filePath: "/tmp/Dahlia", directoryHint: .isDirectory),
                isVaultConfirmed: true,
                in: defaults
            )

            SetupTourPresentationPolicy.markCompleted(in: defaults)

            #expect(defaults.integer(forKey: SetupTourPresentationPolicy.userDefaultsKey) ==
                SetupTourPresentationPolicy.currentVersion)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.progressStepUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.vaultPathUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.vaultConfirmedUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.providerUserDefaultsKey) == nil)
            #expect(defaults.object(forKey: SetupTourPresentationPolicy.databricksProfileUserDefaultsKey) == nil)
        }

        @Test
        func interruptedInitialTourRestoresItsProviderDraft() throws {
            let suiteName = "SetupTourProviderProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            SetupTourPresentationPolicy.saveProgress(
                step: .modelProvider,
                vaultURL: URL(filePath: "/tmp/Dahlia", directoryHint: .isDirectory),
                isVaultConfirmed: true,
                in: defaults
            )
            let draft = VaultAISettingsModel(setupDefaults: defaults)
            draft.localProvider = .databricks
            draft.databricksProfile = "setup-profile"

            let restored = VaultAISettingsModel(setupDefaults: defaults)

            #expect(restored.localProvider == .databricks)
            #expect(restored.databricksProfile == "setup-profile")
        }

        @Test
        func interruptedInitialTourRestoresItsStepAndVault() throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let selectedURL = URL(filePath: "/tmp/Selected Dahlia", directoryHint: .isDirectory)
            let model = SetupTourModel(mode: .initial, currentVault: nil, progressDefaults: defaults)

            model.selectVaultURL(selectedURL)
            model.confirmVaultSelection()
            model.advance()

            let restoredModel = SetupTourModel(mode: .initial, currentVault: nil, progressDefaults: defaults)
            #expect(restoredModel.currentStep == .workingLanguages)
            #expect(restoredModel.selectedVaultURL == selectedURL)
            #expect(restoredModel.isVaultLocationConfirmed)
        }

        @Test
        func incompleteVaultProgressReturnsToVaultConfirmation() throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(SetupTourStep.modelProvider.rawValue, forKey: SetupTourPresentationPolicy.progressStepUserDefaultsKey)

            let restoredModel = SetupTourModel(mode: .initial, currentVault: nil, progressDefaults: defaults)

            #expect(restoredModel.currentStep == .vault)
            #expect(!restoredModel.isVaultLocationConfirmed)
        }

        @Test
        func vaultStepRequiresExplicitConfirmationBeforeAdvancing() {
            let model = SetupTourModel(mode: .initial, currentVault: nil)

            #expect(model.currentStep == .vault)
            #expect(!model.isVaultLocationConfirmed)
            #expect(!model.canContinue)

            model.advance()
            #expect(model.currentStep == .vault)

            model.confirmVaultSelection()
            model.advance()

            #expect(model.currentStep == .workingLanguages)
            #expect(model.isVaultLocationConfirmed)
        }

        @Test
        func newVaultNameResolvesInsideDocuments() {
            #expect(SetupTourModel.newVaultURL(named: "Dahlia") == URL.documentsDirectory.appending(
                path: "Dahlia",
                directoryHint: .isDirectory
            ))
            #expect(SetupTourModel.newVaultURL(named: "  Team Notes  ") == URL.documentsDirectory.appending(
                path: "Team Notes",
                directoryHint: .isDirectory
            ))
            #expect(SetupTourModel.newVaultURL(named: "") == nil)
            #expect(SetupTourModel.newVaultURL(named: "Team/Notes") == nil)
        }

        @Test
        func setupUsesTheRequestedConfigurationOrder() {
            #expect(SetupTourStep.allCases == [
                .vault,
                .workingLanguages,
                .permissions,
                .modelProvider,
                .calendar,
                .completion,
            ])
            #expect(SetupTourModel(mode: .initial, currentVault: nil).currentStep == .vault)
        }

        @Test
        func backNavigationStartsAfterTheFirstStep() {
            let model = SetupTourModel(mode: .initial, currentVault: nil)

            #expect(!model.canGoBack)
            model.confirmVaultSelection()
            model.advance()
            #expect(model.currentStep == .workingLanguages)
            #expect(model.canGoBack)
        }

        @Test
        func navigationMovesSequentiallyAndNeverPastCompletion() {
            let model = SetupTourModel(mode: .initial, currentVault: nil)
            model.confirmVaultSelection()
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
        func savedProgressIsDetectedIndependentlyOfItsStep() throws {
            let suiteName = "SetupTourProgressTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            #expect(!SetupTourPresentationPolicy.hasSavedProgress(in: defaults))
            SetupTourPresentationPolicy.saveProgress(
                step: .completion,
                vaultURL: URL(filePath: "/tmp/Dahlia", directoryHint: .isDirectory),
                isVaultConfirmed: true,
                in: defaults
            )
            #expect(SetupTourPresentationPolicy.hasSavedProgress(in: defaults))
        }

        @Test
        func selectingAnotherVaultRequiresASecondConfirmation() {
            let currentVault = VaultRecord(
                id: .v7(),
                path: "/tmp/Current",
                name: "Current",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let model = SetupTourModel(mode: .manual, currentVault: currentVault)

            #expect(model.isVaultLocationConfirmed)
            #expect(model.currentStep == .vault)
            #expect(model.canContinue)

            model.selectVaultURL(URL(filePath: "/tmp/Other", directoryHint: .isDirectory))

            #expect(!model.isVaultLocationConfirmed)
            #expect(model.currentStep == .vault)
            #expect(!model.canContinue)
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
