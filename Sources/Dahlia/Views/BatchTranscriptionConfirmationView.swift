import SwiftUI

struct BatchTranscriptionConfirmationView: View {
    let locales: [Locale]
    let automaticLanguageLocales: [Locale]
    let displayLocale: Locale
    let isRetranscription: Bool
    let onStart: (BatchTranscriptionLanguageSelection, Bool, SummaryGenerationOptions?) -> Void
    let onPostpone: () -> Void

    @State private var languageSelection: BatchTranscriptionLanguageSelection
    @State private var deleteAudioAfterTranscription: Bool
    @State private var generateSummaryAfterBatchTranscription: Bool
    @State private var exportBatchSummaryToVault: Bool
    @State private var exportBatchSummaryToGoogleDocs: Bool
    @State private var previousMeetingCount: Int

    init(
        locales: [Locale],
        automaticLanguageLocales: [Locale],
        displayLocale: Locale,
        initialLanguageSelection: BatchTranscriptionLanguageSelection,
        initiallyRetainsAudioAfterBatch: Bool,
        initiallyGeneratesSummary: Bool,
        summaryGenerationOptions: SummaryGenerationOptions,
        isRetranscription: Bool,
        onStart: @escaping (BatchTranscriptionLanguageSelection, Bool, SummaryGenerationOptions?) -> Void,
        onPostpone: @escaping () -> Void
    ) {
        self.locales = locales
        self.automaticLanguageLocales = automaticLanguageLocales
        self.displayLocale = displayLocale
        self.onStart = onStart
        self.onPostpone = onPostpone
        self.isRetranscription = isRetranscription
        _languageSelection = State(initialValue: initialLanguageSelection)
        _deleteAudioAfterTranscription = State(initialValue: !initiallyRetainsAudioAfterBatch)
        _generateSummaryAfterBatchTranscription = State(initialValue: initiallyGeneratesSummary)
        _exportBatchSummaryToVault = State(initialValue: summaryGenerationOptions.exportOptions.exportsToVault)
        _exportBatchSummaryToGoogleDocs = State(initialValue: summaryGenerationOptions.exportOptions.exportsToGoogleDocs)
        _previousMeetingCount = State(initialValue: summaryGenerationOptions.previousMeetingCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isRetranscription ? L10n.batchRetranscriptionConfirmationTitle : L10n.batchTranscriptionConfirmationTitle)
                    .font(.headline)

                Text(isRetranscription
                    ? L10n.batchRetranscriptionConfirmationDescription
                    : L10n.batchTranscriptionConfirmationDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            BatchTranscriptionOptionsForm(
                locales: locales,
                automaticLanguageLocales: automaticLanguageLocales,
                displayLocale: displayLocale,
                languageSelection: $languageSelection,
                deleteAudioAfterTranscription: $deleteAudioAfterTranscription,
                generateSummaryAfterBatchTranscription: $generateSummaryAfterBatchTranscription,
                exportBatchSummaryToVault: $exportBatchSummaryToVault,
                exportBatchSummaryToGoogleDocs: $exportBatchSummaryToGoogleDocs,
                previousMeetingCount: $previousMeetingCount
            )

            Divider()

            HStack {
                Spacer()
                Button(L10n.later, action: onPostpone)
                    .keyboardShortcut(.cancelAction)
                if isRetranscription {
                    Button(L10n.retranscribe, action: startTranscription)
                        .disabled(languageSelection == .automatic && automaticLanguageLocales.isEmpty)
                } else {
                    Button(L10n.startTranscription, action: startTranscription)
                        .keyboardShortcut(.defaultAction)
                        .disabled(languageSelection == .automatic && automaticLanguageLocales.isEmpty)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 520, minHeight: 440, idealHeight: 500)
        .onChange(of: generateSummaryAfterBatchTranscription) { _, _ in persistSummaryPreferencesIfNeeded() }
        .onChange(of: exportBatchSummaryToVault) { _, _ in persistSummaryPreferencesIfNeeded() }
        .onChange(of: exportBatchSummaryToGoogleDocs) { _, _ in persistSummaryPreferencesIfNeeded() }
        .onChange(of: previousMeetingCount) { _, _ in persistSummaryPreferencesIfNeeded() }
    }

    private func startTranscription() {
        let summaryOptions = generateSummaryAfterBatchTranscription
            ? SummaryGenerationOptions(
                previousMeetingCount: AppSettings.normalizedSummaryPreviousMeetingCount(previousMeetingCount),
                exportOptions: SummaryExportOptions(
                    exportsToVault: exportBatchSummaryToVault,
                    exportsToGoogleDocs: exportBatchSummaryToGoogleDocs
                )
            )
            : nil
        onStart(languageSelection, !deleteAudioAfterTranscription, summaryOptions)
    }

    private func persistSummaryPreferencesIfNeeded() {
        guard !isRetranscription else { return }
        let settings = AppSettings.shared
        settings.generateSummaryAfterBatchTranscription = generateSummaryAfterBatchTranscription
        settings.exportBatchSummaryToVault = exportBatchSummaryToVault
        settings.exportBatchSummaryToGoogleDocs = exportBatchSummaryToGoogleDocs
        settings.summaryPreviousMeetingCount = previousMeetingCount
    }
}
