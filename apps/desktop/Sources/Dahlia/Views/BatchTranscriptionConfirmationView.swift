import SwiftUI

struct BatchTranscriptionConfirmationView: View {
    let locales: [Locale]
    let automaticLanguageLocales: [Locale]
    let displayLocale: Locale
    let projects: [FlatProjectRow]
    let processingMethod: RecordingProcessingMethod?
    let isRetranscription: Bool
    let allowsRecordedLanguageSelection: Bool
    let onStart: (BatchTranscriptionLanguageSelection, Bool, SummaryGenerationOptions, UUID?) -> String?
    let onPostpone: () -> Void

    @State private var languageSelection: BatchTranscriptionLanguageSelection
    @State private var generateSummaryAfterBatchTranscription: Bool
    @State private var summaryDetailLevel: SummaryDetailLevel?
    @State private var exportBatchSummaryToWorkspace: Bool
    @State private var exportBatchSummaryToGoogleDocs: Bool
    @State private var selectedProjectId: UUID?
    @State private var errorMessage: String?

    init(
        locales: [Locale],
        automaticLanguageLocales: [Locale],
        displayLocale: Locale,
        projects: [FlatProjectRow],
        initialProjectId: UUID?,
        initialErrorMessage: String?,
        initialLanguageSelection: BatchTranscriptionLanguageSelection,
        allowsRecordedLanguageSelection: Bool,
        initiallyGeneratesSummary: Bool,
        summaryGenerationOptions: SummaryGenerationOptions,
        isRetranscription: Bool,
        processingMethod: RecordingProcessingMethod? = nil,
        onStart: @escaping (BatchTranscriptionLanguageSelection, Bool, SummaryGenerationOptions, UUID?) -> String?,
        onPostpone: @escaping () -> Void
    ) {
        self.locales = locales
        self.automaticLanguageLocales = automaticLanguageLocales
        self.displayLocale = displayLocale
        self.projects = projects
        self.onStart = onStart
        self.onPostpone = onPostpone
        self.processingMethod = processingMethod
        self.isRetranscription = isRetranscription
        self.allowsRecordedLanguageSelection = allowsRecordedLanguageSelection
        _languageSelection = State(initialValue: initialLanguageSelection)
        _generateSummaryAfterBatchTranscription = State(initialValue: initiallyGeneratesSummary)
        _summaryDetailLevel = State(initialValue: summaryGenerationOptions.detailLevel)
        _exportBatchSummaryToWorkspace = State(initialValue: summaryGenerationOptions.exportOptions.exportsToWorkspace)
        _exportBatchSummaryToGoogleDocs = State(initialValue: summaryGenerationOptions.exportOptions.exportsToGoogleDocs)
        _selectedProjectId = State(initialValue: initialProjectId)
        _errorMessage = State(initialValue: initialErrorMessage)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(confirmationText.title)
                    .font(.headline)

                Text(confirmationText.description)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            BatchTranscriptionOptionsForm(
                locales: locales,
                automaticLanguageLocales: automaticLanguageLocales,
                displayLocale: displayLocale,
                allowsRecordedLanguageSelection: allowsRecordedLanguageSelection,
                languageSelection: $languageSelection,
                generateSummaryAfterBatchTranscription: $generateSummaryAfterBatchTranscription,
                summaryDetailLevel: $summaryDetailLevel,
                exportBatchSummaryToWorkspace: $exportBatchSummaryToWorkspace,
                exportBatchSummaryToGoogleDocs: $exportBatchSummaryToGoogleDocs,
                projects: projects,
                selectedProjectId: $selectedProjectId,
                processingMethod: processingMethod
            )

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.later, action: onPostpone)
                    .keyboardShortcut(.cancelAction)
                if isRetranscription {
                    Button(L10n.retranscribe, action: startTranscription)
                        .disabled(isStartDisabled)
                } else {
                    Button(processingMethod != nil ? L10n.startProcessing : L10n.startTranscription, action: startTranscription)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isStartDisabled)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 520, minHeight: 440, idealHeight: 500)
        .onChange(of: generateSummaryAfterBatchTranscription) { _, _ in persistSummaryPreferencesIfNeeded() }
        .onChange(of: exportBatchSummaryToWorkspace) { _, _ in persistSummaryPreferencesIfNeeded() }
        .onChange(of: exportBatchSummaryToGoogleDocs) { _, _ in persistSummaryPreferencesIfNeeded() }
    }

    private var confirmationText: (title: String, description: String) {
        if processingMethod != nil {
            (L10n.processingConfirmationTitle, L10n.processingConfirmationDescription)
        } else if isRetranscription {
            (L10n.batchRetranscriptionConfirmationTitle, L10n.batchRetranscriptionConfirmationDescription)
        } else {
            (L10n.batchTranscriptionConfirmationTitle, L10n.batchTranscriptionConfirmationDescription)
        }
    }

    private var isStartDisabled: Bool {
        (processingMethod == nil || processingMethod == .transcript)
            && languageSelection == .automatic && automaticLanguageLocales.isEmpty
    }

    private func startTranscription() {
        let summaryOptions = SummaryGenerationOptions(
            exportOptions: SummaryExportOptions(
                exportsToWorkspace: exportBatchSummaryToWorkspace,
                exportsToGoogleDocs: exportBatchSummaryToGoogleDocs
            ),
            detailLevel: summaryDetailLevel
        )
        errorMessage = onStart(
            languageSelection,
            processingMethod != nil || generateSummaryAfterBatchTranscription,
            summaryOptions,
            selectedProjectId
        )
    }

    private func persistSummaryPreferencesIfNeeded() {
        guard !isRetranscription else { return }
        let settings = AppSettings.shared
        if processingMethod == nil { settings.generateSummaryAfterBatchTranscription = generateSummaryAfterBatchTranscription }
        settings.exportBatchSummaryToWorkspace = exportBatchSummaryToWorkspace
        settings.exportBatchSummaryToGoogleDocs = exportBatchSummaryToGoogleDocs
    }
}
