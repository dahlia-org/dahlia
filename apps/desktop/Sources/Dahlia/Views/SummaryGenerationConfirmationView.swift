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
    @State private var overrides = SummaryGenerationOptions.Overrides()
    @State private var catalog = CodexModelCatalog(service: .macInference)
    @Bindable private var serverCatalog = ServerAccountSettingsModel.shared

    let title: String
    let description: String
    let actionTitle: String
    let projects: [FlatProjectRow]?
    let loadSourceAvailability: () async throws -> SummaryGenerationSourceAvailability
    let onCancel: () -> Void
    let onGenerate: (SummaryGenerationOptions, UUID?) -> String?

    init(
        title: String = L10n.summaryGenerationConfirmationTitle,
        description: String = L10n.summaryGenerationConfirmationDescription,
        actionTitle: String = L10n.generateSummary,
        projects: [FlatProjectRow]? = nil,
        initialProjectId: UUID? = nil,
        initialDetailLevel _: SummaryDetailLevel,
        loadSourceAvailability: @escaping () async throws -> SummaryGenerationSourceAvailability,
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
                    LabeledContent(L10n.processingLocation, value: usesRemote ? L10n.remoteProcessing : L10n.localProcessing)
                    Picker(L10n.summaryOutputLanguage, selection: $overrides.outputLanguage) {
                        Text(L10n.workspaceGenerationDefault).tag(SummaryLanguage?.none)
                        ForEach(SummaryLanguage.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Picker(L10n.summaryModel, selection: modelSelection) {
                        Text("\(L10n.workspaceGenerationDefault) — \(modelName(defaultModel))").tag(String?.none)
                        if usesRemote { Text(L10n.automaticModelPreference).tag(Optional("")) }
                        if let model = overrides.model, !model.isEmpty, !modelIDs.contains(model) {
                            Text(isModelCatalogLoaded ? "\(model) — \(L10n.unavailableModelPreference)" : model).tag(Optional(model))
                        }
                        ForEach(modelIDs, id: \.self) { id in Text(modelName(id)).tag(Optional(id)) }
                    }
                    if isModelCatalogLoaded, !isModelAvailable {
                        SettingsStatusMessage(
                            text: "\(modelName(overrides.model ?? defaultModel)) — \(L10n.unavailableModelPreference)",
                            systemImage: "exclamationmark.triangle", tint: .orange
                        )
                    }
                    Picker(L10n.reasoningEffort, selection: $overrides.reasoningEffort) {
                        Text(L10n.workspaceGenerationDefault).tag(String?.none)
                        if usesRemote { Text(L10n.automaticModelPreference).tag(Optional("")) }
                        if let effort = overrides.reasoningEffort, !effort.isEmpty, !effortOptions.contains(effort) {
                            Text("\(effort) — \(L10n.checkModelPreference)").tag(Optional(effort))
                        }
                        ForEach(effortOptions, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    if let error = modelError {
                        SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
                        Button(L10n.retry) { Task { await loadModels() } }
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
                    .disabled(!isModelAvailable || hasIncompatibleEffort ||
                        isLoadingSources || sourceErrorMessage != nil ||
                        (selectedSource.map { sourceAvailability?.isAvailable($0) != true } ?? true))
            }
            .padding(20)
        }
        .frame(width: 560, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadSources()
            await loadModels()
        }
    }

    private var usesRemote: Bool {
        sourceAvailability?.hasServerConnection == true
    }

    private var defaultModel: String {
        guard let settings = sourceAvailability?.generationSettings else { return "" }
        if !usesRemote { return settings.local.model }
        if selectedSource == .audio { return settings.processing.remote.summaryModel ?? "" }
        return settings.processing.remote.transcriptSummaryModel
            ?? (settings.processing.location == .local ? settings.processing.remote.summaryModel : nil) ?? ""
    }

    private var serverState: ServerAccountSettingsModel.State? {
        sourceAvailability?.accountConnectionID.map { serverCatalog.state(for: $0) }
    }

    private var modelIDs: [String] {
        if usesRemote {
            return serverState?.summaryModels.filter { $0.supportsSummary(method: selectedSource == .audio ? "audio" : "transcript") }.map(\.id) ?? []
        }
        return catalog.models.map(\.model)
    }

    private func modelName(_ id: String) -> String {
        if id.isEmpty { return L10n.automaticModelPreference }
        if usesRemote { return serverState?.summaryModels.first { $0.id == id }?.displayName ?? id }
        return catalog.models.first { $0.model == id }?.displayName ?? id
    }

    private var modelSelection: Binding<String?> {
        Binding(get: { overrides.model }, set: { model in
            overrides.selectModel(
                model,
                defaultReasoningEffort: usesRemote ? "" : catalog.resolvedEffort(current: "", modelID: model ?? defaultModel)
            )
        })
    }

    private var isModelAvailable: Bool {
        overrides.isModelAvailable(defaultModel: defaultModel, modelIDs: modelIDs, allowsAutomatic: usesRemote)
    }

    private var isModelCatalogLoaded: Bool {
        guard !isLoadingSources, selectedSource != nil, modelError == nil else { return false }
        if usesRemote { return serverState?.isModelCatalogLoaded == true }
        return catalog.hasAttemptedLoad && !catalog.isLoading
    }

    private var hasIncompatibleEffort: Bool {
        guard let effort = overrides.reasoningEffort?.nilIfBlank else { return false }
        return !effortOptions.contains(effort)
    }

    private var effortOptions: [String] {
        let id = overrides.model ?? defaultModel
        if usesRemote { return serverState?.summaryModels.first { $0.id == id }?.supportedReasoningLevels.map(\.effort) ?? [] }
        return catalog.effortOptions(modelID: id).map(\.reasoningEffort)
    }

    private var modelError: String? {
        usesRemote ? serverState?.modelErrorMessage ?? serverState?.errorMessage : catalog.errorMessage
    }

    private func loadModels() async {
        if let connectionID = sourceAvailability?.accountConnectionID {
            await serverCatalog.refresh(connectionID: connectionID, reloadModels: true)?.value
        } else if sourceAvailability != nil {
            let provider = WorkspaceAISettingsModel.shared.localAccountSettings.runtimeProvider
            await catalog.load(forceRefresh: true) {
                try await CodexRuntimeContextCoordinator.macInference.activate(provider: provider)
            }
        }
    }

    private func generateSummary() {
        errorMessage = onGenerate(SummaryGenerationOptions(
            exportOptions: SummaryExportOptions(
                exportsToWorkspace: exportsToWorkspace,
                exportsToGoogleDocs: exportsToGoogleDocs
            ),
            detailLevel: detailLevel,
            source: selectedSource,
            overrides: overrides
        ), selectedProjectId)
        if errorMessage == nil {
            onCancel()
        }
    }

    private func loadSources() async {
        isLoadingSources = true
        sourceErrorMessage = nil
        do {
            let availability = try await loadSourceAvailability()
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
