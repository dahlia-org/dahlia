import SwiftUI

struct WorkspaceTranscriptionLanguagesSection: View {
    @Bindable private var model = WorkspaceAISettingsModel.shared
    @State private var languages: [AppLanguageSelection] = []
    @State private var searchText = ""

    private var settings: WorkspaceGenerationSettings.Transcription { model.generationSettings.transcription }

    var body: some View {
        Section {
            DisclosureGroup {
                Picker(L10n.languageRange, selection: languageScope) {
                    ForEach(AppLanguageScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }

                if settings.languageScope == .selected {
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
                }
            } label: {
                LabeledContent(L10n.automaticDetectionLanguagesTitle) {
                    Text(AppLanguageSelectionRow.selectionSummary(
                        scope: settings.languageScope,
                        identifiers: Set(settings.languageIdentifiers)
                    ))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            languages = await AppLanguageCatalog.load()
        }
    }

    private var languageScope: Binding<AppLanguageScope> {
        Binding {
            settings.languageScope
        } set: { scope in
            var transcription = settings
            transcription.languageScope = scope
            if scope == .selected, transcription.languageIdentifiers.isEmpty {
                transcription.languageIdentifiers = ["ja"]
            }
            model.generationSettings.transcription = transcription
        }
    }

    private func languageSelection(_ identifier: String) -> Binding<Bool> {
        Binding {
            settings.languageIdentifiers.contains(identifier)
        } set: { enabled in
            model.generationSettings.transcription.languageIdentifiers = AppLanguageSelection.updating(
                Set(settings.languageIdentifiers), identifier: identifier, isEnabled: enabled
            ).sorted()
        }
    }

    private var filteredLanguages: [AppLanguageSelection] {
        languages.filter {
            searchText.isEmpty || $0.id.localizedStandardContains(searchText)
                || $0.displayName().localizedStandardContains(searchText)
        }
    }
}
