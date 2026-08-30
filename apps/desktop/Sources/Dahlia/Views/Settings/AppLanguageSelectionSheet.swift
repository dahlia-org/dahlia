import SwiftUI

struct AppLanguageSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (AppLanguageScope, Set<String>) -> Void

    @State private var draft: AppLanguageSelectionDraft
    @State private var languages: [AppLanguageSelection] = []
    @State private var searchText = ""
    @State private var isLoading = true

    init(
        scope: AppLanguageScope,
        enabledLanguageIdentifiers: Set<String>,
        onSave: @escaping (AppLanguageScope, Set<String>) -> Void
    ) {
        self.onSave = onSave
        _draft = State(initialValue: AppLanguageSelectionDraft(
            scope: scope,
            enabledLanguageIdentifiers: enabledLanguageIdentifiers
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: L10n.appLanguages)

            Form {
                Section {
                    DahliaSegmentedPicker(
                        title: L10n.languageRange,
                        selection: $draft.scope,
                        options: AppLanguageScope.allCases,
                        label: \.displayName
                    )
                }

                if draft.scope == .selected {
                    Section {
                        TextField(L10n.searchLanguages, text: $searchText)
                            .textFieldStyle(.roundedBorder)

                        if isLoading {
                            ProgressView(L10n.loadingLanguages)
                        } else if filteredLanguages.isEmpty {
                            Text(L10n.noMatchingLanguages)
                                .foregroundStyle(DahliaDesign.secondaryTextColor)
                        } else {
                            ForEach(filteredLanguages) { language in
                                Toggle(isOn: languageBinding(language.id)) {
                                    LabeledContent(language.displayName()) {
                                        Text(language.id)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    } header: {
                        Text(L10n.selectedLanguages)
                    }
                }
            }
            .formStyle(.grouped)

            DahliaSheetActionBar {
                Button(L10n.done, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .frame(minWidth: 500, minHeight: 500)
        .dahliaSimpleWindowStyle()
        .background {
            SheetOutsideClickMonitor(onOutsideClick: dismiss.callAsFunction)
        }
        .task {
            languages = await AppLanguageCatalog.load()
            isLoading = false
        }
    }

    private var filteredLanguages: [AppLanguageSelection] {
        guard !searchText.isEmpty else { return languages }
        return languages.filter {
            $0.id.localizedStandardContains(searchText)
                || $0.displayName().localizedStandardContains(searchText)
        }
    }

    private func languageBinding(_ identifier: String) -> Binding<Bool> {
        Binding {
            draft.enabledLanguageIdentifiers.contains(identifier)
        } set: { enabled in
            draft.enabledLanguageIdentifiers = AppLanguageSelection.updating(
                draft.enabledLanguageIdentifiers,
                identifier: identifier,
                isEnabled: enabled
            )
        }
    }

    private func save() {
        draft.commit(onSave)
        dismiss()
    }
}
