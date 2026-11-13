import SwiftUI
import UniformTypeIdentifiers

struct SearchDictionarySettingsSection: View {
    @Bindable var model: SearchDictionarySettingsModel
    @State private var isImporting = false

    var body: some View {
        Section {
            Picker(L10n.searchDictionary, selection: $model.usesNeologd) {
                Text(L10n.searchDictionaryIPADIC).font(.dahliaBody).tag(false)
                if model.neologdPath != nil {
                    Text("IPADIC NEologd").font(.dahliaBody).tag(true)
                }
            }
            .disabled(model.isBusy || !model.isLoaded)
            .onChange(of: model.usesNeologd) { _, _ in model.selectDictionary() }

            LabeledContent(
                L10n.searchActiveDictionary,
                value: model.activeConfiguration.dictionaryPath == nil ? L10n.searchDictionaryIPADIC : "IPADIC NEologd"
            )

            HStack {
                Text(L10n.searchNeologdDownloadDescription)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isDownloading {
                    ProgressView().controlSize(.small)
                    Button(L10n.cancel) { model.cancelDownload() }
                        .buttonStyle(.dahlia())
                } else if model.neologdPath == nil {
                    Button(L10n.searchDownloadNeologd) { model.download() }
                        .buttonStyle(.dahlia())
                        .disabled(model.isBusy || !model.isLoaded)
                }
            }

            LabeledContent(L10n.searchUserDictionary) {
                HStack {
                    Text(model.configuration.userDictionaryName ?? L10n.searchUserDictionaryNone)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(L10n.searchUserDictionaryImport) { isImporting = true }
                        .buttonStyle(.dahlia())
                    if model.configuration.userDictionaryPath != nil {
                        Button(L10n.searchUserDictionaryRemove) { model.removeUserDictionary() }
                            .buttonStyle(.dahlia())
                    }
                }
                .accessibilityElement(children: .contain)
            }
            .disabled(model.isBusy || !model.isLoaded)

            Text(L10n.searchUserDictionaryDescription)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if model.needsRebuild {
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
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText]) { result in
            switch result {
            case let .success(url): model.importUserDictionary(url)
            case let .failure(error): model.reportImportError(error)
            }
        }
    }
}
