import SwiftUI

struct BatchTranscriptionConfirmationView: View {
    @ObservedObject private var viewModel: CaptionViewModel

    let locales: [Locale]
    let automaticLanguageLocales: [Locale]
    let displayLocale: Locale
    let projects: [FlatProjectRow]
    let processingMethod: RecordingProcessingMethod?
    let usesServerSummary: Bool
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
        viewModel: CaptionViewModel,
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
        usesServerSummary: Bool,
        onStart: @escaping (BatchTranscriptionLanguageSelection, Bool, SummaryGenerationOptions, UUID?) -> String?,
        onPostpone: @escaping () -> Void
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.locales = locales
        self.automaticLanguageLocales = automaticLanguageLocales
        self.displayLocale = displayLocale
        self.projects = projects
        self.onStart = onStart
        self.onPostpone = onPostpone
        self.processingMethod = processingMethod
        self.usesServerSummary = usesServerSummary
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
                processingMethod: processingMethod,
                usesServerSummary: usesServerSummary,
                isRetranscription: isRetranscription
            )

            if isRetranscription, usesServerSummary,
               let serverRetranscriptionUnavailableReason = viewModel.serverRetranscriptionUnavailableReason {
                HStack(alignment: .top, spacing: 8) {
                    Label(serverRetranscriptionUnavailableReason, systemImage: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if viewModel.canRetryServerRetranscriptionAvailability {
                        Button(L10n.retry, action: viewModel.retryServerRetranscriptionAvailability)
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

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
        .frame(
            minWidth: 500,
            idealWidth: 520,
            minHeight: isRetranscription ? 300 : 440,
            idealHeight: isRetranscription ? 340 : 500
        )
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
        Self.startDisabled(
            processingMethod: processingMethod,
            languageSelection: languageSelection,
            automaticLanguageLocales: automaticLanguageLocales,
            serverRetranscriptionUnavailable: isRetranscription
                && usesServerSummary
                && (viewModel.isCheckingServerRetranscriptionAvailability
                    || viewModel.serverRetranscriptionUnavailableReason != nil)
        )
    }

    static func startDisabled(
        processingMethod: RecordingProcessingMethod?,
        languageSelection: BatchTranscriptionLanguageSelection,
        automaticLanguageLocales: [Locale],
        serverRetranscriptionUnavailable: Bool = false
    ) -> Bool {
        serverRetranscriptionUnavailable || ((processingMethod == nil || processingMethod == .transcript)
            && languageSelection == .automatic && automaticLanguageLocales.isEmpty)
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
            !isRetranscription && (processingMethod != nil || generateSummaryAfterBatchTranscription),
            isRetranscription ? .manual : summaryOptions,
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
