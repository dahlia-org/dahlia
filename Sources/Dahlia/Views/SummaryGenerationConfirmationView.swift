import SwiftUI

struct SummaryGenerationConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var exportsToVault = SummaryExportOptions.manual.exportsToVault
    @State private var exportsToGoogleDocs = SummaryExportOptions.manual.exportsToGoogleDocs
    @State private var detailLevel: SummaryDetailLevel
    @State private var selectedProjectId: UUID?
    @State private var errorMessage: String?

    let title: String
    let description: String
    let actionTitle: String
    let projects: [FlatProjectRow]?
    let onGenerate: (SummaryGenerationOptions, UUID?) -> String?

    init(
        title: String = L10n.summaryGenerationConfirmationTitle,
        description: String = L10n.summaryGenerationConfirmationDescription,
        actionTitle: String = L10n.generateSummary,
        projects: [FlatProjectRow]? = nil,
        initialProjectId: UUID? = nil,
        initialDetailLevel: SummaryDetailLevel,
        onGenerate: @escaping (SummaryGenerationOptions, UUID?) -> String?
    ) {
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.projects = projects
        self.onGenerate = onGenerate
        _detailLevel = State(initialValue: initialDetailLevel)
        _selectedProjectId = State(initialValue: initialProjectId)
        _errorMessage = State(initialValue: nil)
    }

    init(
        title: String = L10n.summaryGenerationConfirmationTitle,
        description: String = L10n.summaryGenerationConfirmationDescription,
        actionTitle: String = L10n.generateSummary,
        initialDetailLevel: SummaryDetailLevel,
        onGenerate: @escaping (SummaryGenerationOptions) -> Void
    ) {
        self.init(
            title: title,
            description: description,
            actionTitle: actionTitle,
            initialDetailLevel: initialDetailLevel
        ) { options, _ in
            onGenerate(options)
            return nil
        }
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
                Section(L10n.summaryAndExport) {
                    if let projects {
                        SummaryProjectPicker(projects: projects, selection: $selectedProjectId)
                    }

                    SummaryGenerationOptionsControls(
                        detailLevel: $detailLevel,
                        exportsToVault: $exportsToVault,
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
                Button(L10n.cancel, role: .cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: generateSummary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 520, minHeight: 340, idealHeight: 380)
    }

    private func generateSummary() {
        errorMessage = onGenerate(SummaryGenerationOptions(
            exportOptions: SummaryExportOptions(
                exportsToVault: exportsToVault,
                exportsToGoogleDocs: exportsToGoogleDocs
            ),
            detailLevel: detailLevel
        ), selectedProjectId)
        if errorMessage == nil {
            dismiss()
        }
    }
}
