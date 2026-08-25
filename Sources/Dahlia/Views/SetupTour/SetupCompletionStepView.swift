import SwiftUI

struct SetupCompletionStepView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissionModel = PermissionGuideModel()
    var model: SetupTourModel
    let onReviewVault: () -> Void
    let onReviewPermissions: () -> Void

    var body: some View {
        Form {
            Section(L10n.setupSummary) {
                LabeledContent(
                    L10n.languageRange,
                    value: AppLanguageSelectionRow.selectionSummary(
                        scope: settings.appLanguageScope,
                        identifiers: settings.enabledLanguageIdentifiers
                    )
                )
                LabeledContent(L10n.primaryLanguage, value: settings.llmSummaryLanguage.displayName)
                LabeledContent(L10n.modelProvider, value: settings.codexAccountProvider.displayName)
            }

            Section(L10n.permissions) {
                ForEach(PermissionSetupStepView.permissions) { permission in
                    LabeledContent(permission.title) {
                        HStack {
                            let status = permissionModel.status(for: permission)
                            Label(status.label, systemImage: status.systemImage)

                            if status != .granted {
                                Button(L10n.edit, action: onReviewPermissions)
                                    .buttonStyle(.dahlia())
                            }
                        }
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )

                    Button(L10n.edit, action: onReviewVault)
                        .buttonStyle(.dahlia())
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            permissionModel.refresh()
        }
    }
}
