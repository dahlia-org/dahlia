import SwiftUI

struct SummaryGenerationConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var previousMeetingCount: Int
    @State private var exportsToVault = SummaryExportOptions.manual.exportsToVault
    @State private var exportsToGoogleDocs = SummaryExportOptions.manual.exportsToGoogleDocs

    let onGenerate: (SummaryGenerationOptions) -> Void

    init(onGenerate: @escaping (SummaryGenerationOptions) -> Void) {
        self.onGenerate = onGenerate
        _previousMeetingCount = State(initialValue: AppSettings.shared.summaryPreviousMeetingCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.summaryGenerationConfirmationTitle)
                    .font(.headline)
                Text(L10n.summaryGenerationConfirmationDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section(L10n.summaryAndExport) {
                    SummaryGenerationOptionsControls(
                        previousMeetingCount: $previousMeetingCount,
                        exportsToVault: $exportsToVault,
                        exportsToGoogleDocs: $exportsToGoogleDocs,
                        isEnabled: true
                    )
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(L10n.cancel, role: .cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.generateSummary, action: generateSummary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 520, minHeight: 340, idealHeight: 380)
    }

    private func generateSummary() {
        AppSettings.shared.summaryPreviousMeetingCount = previousMeetingCount
        onGenerate(SummaryGenerationOptions(
            previousMeetingCount: AppSettings.shared.summaryPreviousMeetingCount,
            exportOptions: SummaryExportOptions(
                exportsToVault: exportsToVault,
                exportsToGoogleDocs: exportsToGoogleDocs
            )
        ))
        dismiss()
    }
}
