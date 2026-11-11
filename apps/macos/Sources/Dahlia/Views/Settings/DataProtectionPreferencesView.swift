import DahliaMeetingAccess
import SwiftUI

struct DataProtectionPreferencesView: View {
    @AppStorage(ScreenshotFileStore.budgetDefaultsKey) private var screenshotCacheGiB = 2
    private static let initialRetentionDays = 30
    @ObservedObject private var settings = AppSettings.shared
    @State private var pendingShorterAudioRetentionPeriod: BatchAudioRetentionPeriod?
    @State private var isShowingAudioRetentionConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.forever, isOn: Binding(
                    get: { settings.serverContentRetentionDays == 0 },
                    set: { settings.serverContentRetentionDays = $0 ? 0 : Self.initialRetentionDays }
                ))
                .toggleStyle(.switch)
                LabeledContent(L10n.serverContentRetentionDays) {
                    TextField(L10n.serverContentRetentionDays, value: Binding(
                        get: { settings.serverContentRetentionDays == 0 ? Self.initialRetentionDays : settings.serverContentRetentionDays },
                        set: { if $0 > 0 { settings.serverContentRetentionDays = $0 } }
                    ), format: .number.grouping(.never))
                        .disabled(settings.serverContentRetentionDays == 0)
                }
            } header: {
                Text(L10n.serverContentRetention)
                    .font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.serverContentRetentionDescription)
            }

            Section {
                Picker(L10n.screenshotCacheLimit, selection: $screenshotCacheGiB) {
                    ForEach([1, 2, 5, 10], id: \.self) { size in
                        Text("\(size) GiB").font(.dahliaBody).tag(size)
                    }
                }
            } footer: {
                Text(L10n.screenshotCacheDescription)
            }

            Section {
                DahliaMenuPicker(
                    title: L10n.batchAudioRetentionPeriod,
                    description: L10n.batchAudioRetentionPeriodDescription,
                    selection: audioRetentionPeriodSelection,
                    options: BatchAudioRetentionPeriod.allCases,
                    label: \.displayName
                )
                DahliaMenuPicker(
                    title: L10n.batchTranscriptionStallTimeout,
                    description: L10n.batchTranscriptionStallTimeoutDescription,
                    selection: $settings.batchTranscriptionStallTimeout,
                    options: BatchTranscriptionStallTimeout.allCases,
                    label: \.displayName
                )
            } header: {
                Text(L10n.transcriptionRecoverySettings)
                    .font(.dahliaSectionHeader)
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task(id: screenshotCacheGiB) {
            await ScreenshotContentProvider.shared.trimCache()
        }
        .confirmationDialog(
            L10n.shortenBatchAudioRetentionPeriodTitle,
            isPresented: $isShowingAudioRetentionConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.apply, role: .destructive, action: confirmShorterAudioRetentionPeriod)
            Button(L10n.cancel, role: .cancel, action: cancelShorterAudioRetentionPeriod)
        } message: {
            Text(L10n.shortenBatchAudioRetentionPeriodMessage)
        }
    }

    private var audioRetentionPeriodSelection: Binding<BatchAudioRetentionPeriod> {
        Binding(
            get: { settings.batchAudioRetentionPeriod },
            set: { applyAudioRetentionPeriodChange($0) }
        )
    }

    private func applyAudioRetentionPeriodChange(_ newValue: BatchAudioRetentionPeriod) {
        guard newValue != settings.batchAudioRetentionPeriod else { return }
        guard newValue.isShorter(than: settings.batchAudioRetentionPeriod) else {
            settings.batchAudioRetentionPeriod = newValue
            return
        }
        pendingShorterAudioRetentionPeriod = newValue
        Task { @MainActor in
            await Task.yield()
            guard pendingShorterAudioRetentionPeriod == newValue else { return }
            isShowingAudioRetentionConfirmation = true
        }
    }

    private func confirmShorterAudioRetentionPeriod() {
        guard let pendingShorterAudioRetentionPeriod else { return }
        settings.batchAudioRetentionPeriod = pendingShorterAudioRetentionPeriod
        self.pendingShorterAudioRetentionPeriod = nil
    }

    private func cancelShorterAudioRetentionPeriod() {
        pendingShorterAudioRetentionPeriod = nil
    }

}
