import SwiftUI
import UniformTypeIdentifiers

struct SearchDictionarySettingsSection: View {
    @Bindable var model: SearchDictionarySettingsModel
    @State private var isImporting = false
    @State private var pendingImport: URL?
    @State private var isConfirmingReplacement = false
    @State private var isConfirmingClear = false

    var body: some View {
        Section {
            Picker(L10n.searchDictionary, selection: $model.selectedDictionaryID) {
                Text(L10n.searchDictionaryIPADIC).font(.dahliaBody).tag("")
                ForEach(model.neologdReleases) { release in
                    Text(releaseTitle(release))
                        .font(.dahliaBody)
                        .tag(release.id)
                        .disabled(!release.version.hasPrefix("6."))
                }
            }
            .disabled(model.isBusy || !model.isLoaded)
            .onChange(of: model.selectedDictionaryID) { _, _ in model.selectDictionary() }

            LabeledContent(L10n.searchActiveDictionary, value: model.activeDictionaryName)
            if model.needsCompatibleDictionary {
                SettingsStatusMessage(text: L10n.searchNeologdUpgradeRequired, systemImage: "exclamationmark.triangle", tint: .orange)
            }

            HStack {
                Text(L10n.searchNeologdDownloadDescription)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isDownloading {
                    ProgressView(L10n.searchNeologdDownloading).controlSize(.small)
                    Button(L10n.cancel) { Task { await model.cancelDownload() } }
                        .buttonStyle(.dahlia())
                }
                if model.isLoadingReleases {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(L10n.searchNeologdRefresh)
                } else {
                    Button(L10n.searchNeologdRefresh) {
                        Task { await model.refreshAvailableReleases() }
                    }
                    .buttonStyle(.dahlia())
                    .disabled(model.isBusy || !model.isLoaded)
                }
            }
            if let error = model.catalogError {
                SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
            }

            LabeledContent(L10n.searchUserDictionary) {
                HStack {
                    Text(model.configuration.userDictionaryName ?? L10n.searchUserDictionaryNone)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L10n.searchUserDictionaryImport) { isImporting = true }
                        .buttonStyle(.dahlia())
                    if model.configuration.userDictionaryPath != nil || !model.isUserDictionaryValid {
                        Button(L10n.searchUserDictionaryRemove) { isConfirmingClear = true }
                            .buttonStyle(.dahlia())
                    }
                }
                .accessibilityElement(children: .contain)
            }
            .disabled(model.isBusy || !model.isLoaded)

            LabeledContent(L10n.searchDictionaryFile) {
                Text(model.userDictionaryPath)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Text(L10n.searchUserDictionaryDescription)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if model.needsRebuild, !model.needsCompatibleDictionary {
                SettingsStatusMessage(text: L10n.searchDictionaryRebuildRequired, systemImage: "arrow.triangle.2.circlepath", tint: .orange)
            }
            if let error = model.errorMessage {
                SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            Link(L10n.searchNeologdLicense, destination: URL(string: "https://github.com/neologd/mecab-ipadic-neologd/blob/master/COPYING")!)
        } header: {
            Text(L10n.searchDictionarySettings).font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.searchDictionaryScope)
        }
        .disabled(!model.isAvailable)
        .task { await model.refreshAvailableReleases() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText]) { result in
            switch result {
            case let .success(url):
                if model.configuration.userDictionaryPath != nil || !model.isUserDictionaryValid {
                    pendingImport = url
                    isConfirmingReplacement = true
                } else {
                    model.importUserDictionary(url)
                }
            case let .failure(error): model.reportError(error)
            }
        }
        .confirmationDialog(L10n.searchDictionaryReplace, isPresented: $isConfirmingReplacement, titleVisibility: .visible) {
            Button(L10n.searchUserDictionaryImport, role: .destructive) {
                if let pendingImport { model.importUserDictionary(pendingImport) }
                pendingImport = nil
            }
            Button(L10n.cancel, role: .cancel) { pendingImport = nil }
        } message: {
            Text(L10n.searchDictionaryReplaceDescription)
        }
        .confirmationDialog(L10n.searchUserDictionaryRemove, isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button(L10n.delete, role: .destructive) { model.removeUserDictionary() }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.searchDictionaryClearDescription)
        }
    }

    private func releaseTitle(_ release: SearchNeologdRelease) -> String {
        let installed = model.installedNeologdIDs.contains(release.id)
        let status = release.version.hasPrefix("6.")
            ? (installed ? L10n.searchNeologdDownloaded : L10n.searchNeologdDownloadOnSelection)
            : L10n.searchNeologdUnsupported
        let size = !installed && release.size > 0 ? " (\(ByteCountFormatter.string(fromByteCount: release.size, countStyle: .binary)))" : ""
        return "IPADIC NEologd \(release.version) — \(status)\(size)"
    }

}
