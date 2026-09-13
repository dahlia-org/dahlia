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
        initialDetailLevel: SummaryDetailLevel,
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
        let connectionID = AppSettings.shared.currentWorkspace?.accountConnectionId
        let serverDetail = connectionID.flatMap { connectionID -> SummaryDetailLevel? in
            guard let summary = ServerAccountSettingsModel.shared.state(for: connectionID).settings?.summary else { return nil }
            return summary.detailLevel
        }
        _detailLevel = State(initialValue: connectionID == nil ? initialDetailLevel : serverDetail)
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

                Section(L10n.summaryAndExport) {
                    if let projects {
                        SummaryProjectPicker(projects: projects, selection: $selectedProjectId)
                    }

                    SummaryGenerationOptionsControls(
                        detailLevel: $detailLevel,
                        exportsToWorkspace: $exportsToWorkspace,
                        exportsToGoogleDocs: $exportsToGoogleDocs,
                        isEnabled: true
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
                    .disabled(selectedSource.map { sourceAvailability?.isAvailable($0) != true } ?? true)
            }
            .padding(20)
        }
        .frame(width: 560, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(loadSources)
    }

    private func generateSummary() {
        errorMessage = onGenerate(SummaryGenerationOptions(
            exportOptions: SummaryExportOptions(
                exportsToWorkspace: exportsToWorkspace,
                exportsToGoogleDocs: exportsToGoogleDocs
            ),
            detailLevel: detailLevel,
            source: selectedSource
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
        } catch is CancellationError {
            return
        } catch {
            sourceErrorMessage = L10n.summarySourceCheckFailed
        }
        isLoadingSources = false
    }
}
