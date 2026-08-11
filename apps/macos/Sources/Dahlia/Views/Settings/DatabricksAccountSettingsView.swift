import SwiftUI

struct DatabricksAccountSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var controller = DatabricksAccountController()
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Section {
            LabeledContent {
                HStack {
                    DatabricksProfilePicker(
                        selection: $settings.codexDatabricksProfile,
                        profiles: controller.profiles,
                        isLoading: controller.isLoadingProfiles
                    )

                    Button(
                        L10n.refreshDatabricksProfiles,
                        systemImage: "arrow.clockwise",
                        action: refreshProfiles
                    )
                    .labelStyle(.iconOnly)
                    .disabled(controller.isBusy)
                }
            } label: {
                Text(L10n.databricksProfile)
                Text(L10n.databricksProfileDescription)
            }

            if let profile = controller.profile(named: settings.codexDatabricksProfile) {
                LabeledContent(L10n.databricksWorkspaceURL, value: profile.host ?? L10n.workspaceHostUnavailableFromProfile)
                LabeledContent(L10n.databricksWorkspaceID, value: profile.workspaceID ?? L10n.workspaceIDUnavailableFromProfile)
            }

            if controller.isApplyingConfiguration {
                LabeledContent(L10n.codexConfiguration) {
                    ProgressView()
                        .controlSize(.small)
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
            if let resolvedProfile = await controller.prepare(profileName: settings.codexDatabricksProfile) {
                settings.codexDatabricksProfile = resolvedProfile
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private func refreshProfiles() {
        refreshTask?.cancel()
        refreshTask = Task {
            if let resolvedProfile = await controller.prepare(profileName: settings.codexDatabricksProfile) {
                settings.codexDatabricksProfile = resolvedProfile
            }
        }
    }
}
