import SwiftUI

struct SummaryGenerationConfirmationView: View {
    @State private var exportsToWorkspace = SummaryExportOptions.manual.exportsToWorkspace
    @State private var exportsToGoogleDocs = SummaryExportOptions.manual.exportsToGoogleDocs
    @State private var detailLevel: SummaryDetailLevel?
    @State private var selectedProjectId: UUID?
    @State private var selectedSource: SummaryGenerationSource?
    @State private var sourceAvailability: SummaryGenerationSourceAvailability?
    @State private var isLoadingSources = true
    @State private var sourceErrorMessage: String?
    @State private var errorMessage: String?
    @State private var outputLanguage: SummaryLanguage?
    @State private var location: WorkspaceGenerationSettings.SummaryMode?
    @State private var model: String?
    @State private var effort: String?

    let title: String
    let description: String
    let actionTitle: String
    let projects: [FlatProjectRow]?
    let loadSourceAvailability: (WorkspaceGenerationSettings.SummaryMode?) async throws -> SummaryGenerationSourceAvailability
    let onCancel: () -> Void
    let onGenerate: (SummaryGenerationOptions, UUID?) -> String?

    init(
        title: String = L10n.summaryGenerationConfirmationTitle,
        description: String = L10n.summaryGenerationConfirmationDescription,
        actionTitle: String = L10n.generateSummary,
        projects: [FlatProjectRow]? = nil,
        initialProjectId: UUID? = nil,
        initialDetailLevel _: SummaryDetailLevel,
        loadSourceAvailability: @escaping (WorkspaceGenerationSettings.SummaryMode?) async throws -> SummaryGenerationSourceAvailability,
        onCancel: @escaping () -> Void,
        onGenerate: @escaping (SummaryGenerationOptions, UUID?) -> String?
    ) {
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.projects = projects
        self.loadSourceAvailability = loadSourceAvailability
        self.onCancel = onCancel
        self.onGenerate = onGenerate
        _detailLevel = State(initialValue: nil)
        _selectedProjectId = State(initialValue: initialProjectId)
        _errorMessage = State(initialValue: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section(L10n.summaryGenerationSource) {
                    SummaryGenerationSourcePicker(
                        selection: $selectedSource,
                        availability: sourceAvailability,
                        isLoading: isLoadingSources,
                        errorMessage: sourceErrorMessage
                    )
                }

                Section(L10n.generationOverrides) {
                    if sourceAvailability?.hasServerConnection == true {
                        Picker(L10n.processingLocation, selection: $location) {
                            Text(L10n.workspaceGenerationDefault).tag(WorkspaceGenerationSettings.SummaryMode?.none)
                            Text(L10n.localProcessing).tag(Optional(WorkspaceGenerationSettings.SummaryMode.local))
                            Text(L10n.remoteProcessing).tag(Optional(WorkspaceGenerationSettings.SummaryMode.remote))
                        }
                    }
                    Picker(L10n.summaryOutputLanguage, selection: $outputLanguage) {
                        Text(L10n.workspaceGenerationDefault).tag(SummaryLanguage?.none)
                        ForEach(SummaryLanguage.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    TextField(L10n.summaryModel, text: Binding(
                        get: { model ?? defaultModel }, set: { model = $0 }
                    ), prompt: Text(L10n.workspaceGenerationDefault))
                    Picker(L10n.reasoningEffort, selection: $effort) {
                        Text(L10n.workspaceGenerationDefault).tag(String?.none)
                        if usesRemote { Text(L10n.automaticModelPreference).tag(Optional("")) }
                        ForEach(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"], id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }

                Section(L10n.summaryAndExport) {
                    if let projects {
                        SummaryProjectPicker(projects: projects, selection: $selectedProjectId)
                    }

                    SummaryGenerationOptionsControls(
                        detailLevel: $detailLevel,
                        exportsToWorkspace: $exportsToWorkspace,
                        exportsToGoogleDocs: $exportsToGoogleDocs,
                        isEnabled: true,
                        usesServerSummary: usesRemote
                    )
                }
            }
            .formStyle(.grouped)

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
                Button(L10n.cancel, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: generateSummary)
                    .keyboardShortcut(.defaultAction)
                    .disabled((!usesRemote && model != nil && model?.nilIfBlank == nil) || isLoadingSources || sourceErrorMessage != nil ||
                        (selectedSource.map { sourceAvailability?.isAvailable($0) != true } ?? true))
            }
            .padding(20)
        }
        .frame(width: 560, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: location) { await loadSources() }
    }

    private var usesRemote: Bool {
        (location ?? sourceAvailability?.generationSettings?.processing.location) == .remote
    }

    private var defaultModel: String {
        guard let settings = sourceAvailability?.generationSettings else { return "" }
        return usesRemote ? settings.processing.remote.summaryModel ?? "" : settings.local.model
    }

    private func generateSummary() {
        errorMessage = onGenerate(SummaryGenerationOptions(
            exportOptions: SummaryExportOptions(
                exportsToWorkspace: exportsToWorkspace,
                exportsToGoogleDocs: exportsToGoogleDocs
            ),
            detailLevel: detailLevel,
            source: selectedSource,
            overrides: .init(
                outputLanguage: outputLanguage,
                location: location,
                model: model.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                reasoningEffort: effort
            )
        ), selectedProjectId)
        if errorMessage == nil {
            onCancel()
        }
    }

    private func loadSources() async {
        isLoadingSources = true
        sourceErrorMessage = nil
        do {
            let availability = try await loadSourceAvailability(location)
            try Task.checkCancellation()
            sourceAvailability = availability
            selectedSource = availability.preferredSource
            sourceErrorMessage = availability.sourceCheckFailed ? L10n.summarySourceCheckFailed : nil
        } catch is CancellationError {
            return
        } catch {
            sourceErrorMessage = L10n.summarySourceCheckFailed
        }
        isLoadingSources = false
    }
}
