import SwiftUI

struct ServerAccountLanguageSettingsSection: View {
    let connectionID: UUID

    @Bindable private var model = ServerAccountSettingsModel.shared
    @State private var languages: [AppLanguageSelection] = []
    @State private var searchText = ""

    private var state: ServerAccountSettingsModel.State { model.state(for: connectionID) }

    var body: some View {
        Section {
            if let settings = state.settings {
                Picker(L10n.summaryOutputLanguage, selection: outputLanguage) {
                    ForEach(SummaryLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(!state.canEdit)

                DisclosureGroup {
                    Picker(L10n.languageRange, selection: languageScope) {
                        ForEach(AppLanguageScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .disabled(!state.canEdit)

                    if settings.analysisLanguages.scope == .selected {
                        TextField(L10n.searchLanguages, text: $searchText)
                        ScrollView {
                            LazyVStack(alignment: .leading) {
                                ForEach(filteredLanguages) { language in
                                    Toggle(language.displayName(), isOn: languageSelection(language.id))
                                        .toggleStyle(.checkbox)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                        .disabled(!state.canEdit)
                    }
                } label: {
                    LabeledContent(L10n.imageAnalysisLanguages) {
                        Text(AppLanguageSelectionRow.selectionSummary(
                            scope: settings.analysisLanguages.scope,
                            identifiers: Set(settings.analysisLanguages.identifiers)
                        ))
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(L10n.serverAccountSettingsNotLoaded)
                    .foregroundStyle(.secondary)
            }

            if state.isLoading || state.isSaving {
                ProgressView().controlSize(.small)
            }
            if let error = state.errorMessage {
                Text(error).foregroundStyle(.secondary)
                Button(L10n.retry) { model.refresh(connectionID: connectionID) }
                    .disabled(state.isLoading || state.isSaving)
            }
        } header: {
            Text(L10n.serverAccountLanguages)
        } footer: {
            Text(L10n.serverAccountSettingsDescription)
        }
        .task(id: connectionID) {
            if let task = model.refresh(connectionID: connectionID) { await task.value }
            languages = await AppLanguageCatalog.load()
        }
    }

    private var outputLanguage: Binding<SummaryLanguage> {
        Binding {
            state.settings?.outputLanguage ?? .ja
        } set: { language in
            model.save(.init(outputLanguage: language), connectionID: connectionID)
        }
    }

    private var languageScope: Binding<AppLanguageScope> {
        Binding {
            state.settings?.analysisLanguages.scope ?? .all
        } set: { scope in
            guard var selection = state.settings?.analysisLanguages else { return }
            selection.scope = scope
            if scope == .selected, selection.identifiers.isEmpty {
                selection.identifiers = AppSettings.shared.enabledLanguageIdentifiers.sorted()
                if selection.identifiers.isEmpty { selection.identifiers = ["ja"] }
            }
            model.save(.init(analysisLanguages: selection), connectionID: connectionID)
        }
    }

    private func languageSelection(_ identifier: String) -> Binding<Bool> {
        Binding {
            state.settings?.analysisLanguages.identifiers.contains(identifier) == true
        } set: { enabled in
            guard var selection = state.settings?.analysisLanguages else { return }
            selection.identifiers = AppLanguageSelection.updating(
                Set(selection.identifiers), identifier: identifier, isEnabled: enabled
            ).sorted()
            model.save(.init(analysisLanguages: selection), connectionID: connectionID)
        }
    }

    private var filteredLanguages: [AppLanguageSelection] {
        languages.filter {
            searchText.isEmpty || $0.id.localizedStandardContains(searchText)
                || $0.displayName().localizedStandardContains(searchText)
        }
    }
}
