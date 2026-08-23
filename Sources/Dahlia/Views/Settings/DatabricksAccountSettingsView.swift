import SwiftUI

struct DatabricksAccountSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    let controller: DatabricksAccountController
    @State private var refreshTask: Task<Void, Never>?
    @State private var isShowingInstallGuide = false
    @State private var isShowingProfileCreation = false
    @State private var isShowingInstallationAlert = false
    @State private var installationAlertMessage = ""
    @Environment(\.scenePhase) private var scenePhase

    init(controller: DatabricksAccountController = DatabricksAccountController()) {
        self.controller = controller
    }

    var body: some View {
        Section {
            if controller.isCLIAvailable == false {
                SettingsStatusMessage(
                    text: L10n.databricksCLINotInstalled,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )

                HStack {
                    Button(L10n.installDatabricksCLI, systemImage: "terminal") {
                        isShowingInstallGuide = true
                    }
                    .buttonStyle(.dahlia(.primary))

                    Button(L10n.retry, systemImage: "arrow.clockwise", action: refreshProfiles)
                        .buttonStyle(.dahlia())
                        .disabled(controller.isBusy)
                }
            } else {
                profilePickerRow

                Button(L10n.createNewDatabricksProfile, systemImage: "plus") {
                    isShowingProfileCreation = true
                }
                .buttonStyle(.dahlia(.primary))
                .disabled(controller.isBusy)

                if let profile = controller.profile(named: settings.codexDatabricksProfile) {
                    LabeledContent(L10n.databricksWorkspaceID, value: profile.workspaceID ?? L10n.workspaceIDUnavailableFromProfile)
                }
            }

            if controller.isSigningIn {
                LabeledContent(L10n.codexConfiguration) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.codexWaitingForBrowserSignIn)
                }
            } else if controller.isApplyingConfiguration {
                LabeledContent(L10n.codexConfiguration) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.codexConfiguration)
                }
            } else if controller.isConfigured {
                SettingsStatusMessage(
                    text: L10n.databricksConfigured,
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
            }

            if let errorMessage = controller.errorMessage {
                SettingsStatusMessage(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
            }
        } header: {
            Text(L10n.databricks)
        } footer: {
            Text(L10n.databricksCodexDescription)
        }
        .task(id: settings.codexDatabricksProfile) {
            let requestedProfileName = settings.codexDatabricksProfile
            if controller.configuredProfileName == requestedProfileName {
                return
            }
            if let resolvedProfile = await controller.prepare(profileName: requestedProfileName),
               settings.codexDatabricksProfile == requestedProfileName {
                settings.codexDatabricksProfile = resolvedProfile
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, controller.isCLIAvailable == false else { return }
            refreshProfiles()
        }
        .sheet(isPresented: $isShowingInstallGuide) {
            DatabricksCLIInstallGuideView(onInstall: installCLI)
        }
        .sheet(isPresented: $isShowingProfileCreation) {
            DatabricksProfileCreationView(controller: controller) { profileName in
                settings.codexDatabricksProfile = profileName
            }
        }
        .alert(L10n.databricksCLIInstallation, isPresented: $isShowingInstallationAlert) {} message: {
            Text(installationAlertMessage)
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
            if settings.codexAccountProvider == .databricks {
                controller.restoreSelectedProvider()
            }
        }
    }

    private var profilePickerRow: some View {
        LabeledContent {
            HStack {
                DatabricksProfilePicker(
                    selection: $settings.codexDatabricksProfile,
                    profiles: controller.profiles,
                    isLoading: controller.isLoadingProfiles
                )
                .disabled(controller.isBusy)

                Button(
                    L10n.refreshDatabricksProfiles,
                    systemImage: "arrow.clockwise",
                    action: refreshProfiles
                )
                .labelStyle(.iconOnly)
                .dahliaFixedSymbol()
                .buttonStyle(.dahlia())
                .disabled(controller.isBusy)
            }
        } label: {
            Text(L10n.databricksProfile)
            Text(L10n.databricksProfileDescription)
        }
    }

    private func refreshProfiles() {
        refreshTask?.cancel()
        refreshTask = Task {
            let requestedProfileName = settings.codexDatabricksProfile
            if let resolvedProfile = await controller.prepare(profileName: requestedProfileName),
               settings.codexDatabricksProfile == requestedProfileName {
                settings.codexDatabricksProfile = resolvedProfile
            }
        }
    }

    private func installCLI() {
        switch controller.installCLIInTerminal() {
        case .started:
            return
        case .commandCopied:
            installationAlertMessage = L10n.databricksCLIInstallCommandCopied
        case .failed:
            installationAlertMessage = L10n.databricksCLIInstallFailed
        }
        isShowingInstallationAlert = true
    }
}
