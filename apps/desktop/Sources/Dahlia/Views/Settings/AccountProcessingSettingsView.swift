import SwiftUI

struct AccountProcessingSettingsView: View {
    @Binding var connectionID: UUID?
    let onOpenMacInference: () -> Void
    let onOpenLanguageSettings: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var accountSettings = ServerAccountSettingsModel.shared
    @State private var accountController = DahliaCloudAccountController.shared

    private var state: ServerAccountSettingsModel.State? { connectionID.map(accountSettings.state(for:)) }
    private var location: ServerAccountSettings.SummaryMode { state?.settings?.processing?.location ?? .local }
    private var canSelectRemote: Bool { state?.summaryMethods.contains("audio") == true }
    private var connection: DahliaAccountConnection? { accountController.connections.first { $0.id == connectionID } }
    private var style: SummaryStyle {
        connectionID == nil ? SummaryStyle(detailLevel: settings.summaryDetailLevel) : state?.settings?.summary?.style ?? .detailed
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.appliesToAccount, selection: $connectionID) {
                    Text(L10n.localAccount).tag(UUID?.none)
                    if let connectionID, connection == nil {
                        Text(L10n.dahliaAccount).tag(Optional(connectionID))
                    }
                    ForEach(accountController.connections) { connection in
                        Text("\(connection.displayName) · \(connection.origin)").tag(Optional(connection.id))
                    }
                }
                if connectionID != nil {
                    Text(connection?.isSignedIn == true ? L10n.syncedAccountScopeDescription : L10n.signInRequired)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.localAccountScopeDescription).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.settingsAccountSelectionDescription)
            }

            if let connectionID {
                if connection?.isSignedIn == false {
                    Section {
                        Button(L10n.reauthenticate) { accountController.startReauthentication(connectionID: connectionID) }
                            .disabled(accountController.isBusy)
                    }
                } else {
                    Section {
                        if state?.isSaving == true {
                            ProgressView(L10n.saving).controlSize(.small)
                        } else if state?.isLoading == true {
                            ProgressView(L10n.settingsLoading).controlSize(.small)
                        } else if let error = state?.errorMessage {
                            SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
                            Button(L10n.retry) { accountSettings.refresh(connectionID: connectionID) }
                        } else if state?.settings == nil {
                            Text(L10n.serverAccountSettingsNotLoaded).foregroundStyle(.secondary)
                            Button(L10n.retry) { accountSettings.refresh(connectionID: connectionID) }
                        } else {
                            Text(L10n.settingsApplyNextGeneration).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if connectionID == nil || state?.settings != nil {
                Section {
                    Picker(L10n.summaryStyle, selection: styleSelection) {
                        ForEach(SummaryStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Text(style.description).foregroundStyle(.secondary)
                    Picker(L10n.summaryOutputLanguage, selection: outputLanguageSelection) {
                        ForEach(SummaryLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text(L10n.settingsSummaryOutput)
                } footer: {
                    Text(L10n.settingsOutputLanguageDescription)
                }
                .disabled(connectionID != nil && state?.canEdit != true)

                Section {
                    if let connectionID {
                        Picker(L10n.processingLocation, selection: Binding(
                            get: { location },
                            set: { accountSettings.save(.init(processing: .init(location: $0)), connectionID: connectionID) }
                        )) {
                            Text(L10n.localProcessing).tag(ServerAccountSettings.SummaryMode.local)
                            if canSelectRemote || location == .remote {
                                Text(L10n.remoteProcessing).tag(ServerAccountSettings.SummaryMode.remote)
                                    .disabled(!canSelectRemote)
                            }
                        }
                        .disabled(state?.canEdit != true)
                    } else {
                        LabeledContent(L10n.processingLocation, value: L10n.localProcessing)
                    }
                    if location == .local {
                        Button(L10n.macInferencePreferences, systemImage: "arrow.right", action: onOpenMacInference)
                    }
                    if connectionID != nil, !canSelectRemote {
                        Text(L10n.serverSummaryUnavailable).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.transcriptionAndSummary)
                } footer: {
                    Text(location == .local ? L10n.usesMacInferencePreferences : L10n.settingsServerProcessingDescription)
                }

                if let connectionID {
                    if location == .remote {
                        ServerSummarySettingsSection(connectionID: connectionID)
                            .id(connectionID)
                    }
                    ServerAccountLanguageSettingsSection(connectionID: connectionID)
                        .id(connectionID)
                } else {
                    Section {
                        LabeledContent(L10n.imageAnalysisLanguages) {
                            Button(L10n.openLanguageSettings, action: onOpenLanguageSettings)
                        }
                    } footer: {
                        Text(L10n.settingsLocalAnalysisLanguages)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: connectionID) {
            if let connectionID, let task = accountSettings.refresh(connectionID: connectionID) { await task.value }
        }
        .onChange(of: accountController.connections.map(\.id)) { _, ids in
            if let connectionID, !ids.contains(connectionID) { self.connectionID = nil }
        }
    }

    private var styleSelection: Binding<SummaryStyle> {
        Binding(get: { style }, set: { value in
            if let connectionID {
                accountSettings.save(.init(summary: .init(style: value)), connectionID: connectionID)
            } else {
                settings.summaryDetailLevel = value.detailLevel
            }
        })
    }

    private var outputLanguageSelection: Binding<SummaryLanguage> {
        Binding(get: { connectionID == nil ? settings.llmSummaryLanguage : state?.settings?.outputLanguage ?? .ja }, set: { value in
            if let connectionID {
                accountSettings.save(.init(outputLanguage: value), connectionID: connectionID)
            } else {
                settings.llmSummaryLanguage = value
            }
        })
    }
}
