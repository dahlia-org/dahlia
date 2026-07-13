import SwiftUI

struct BatchTranscriptionConfirmationView: View {
    let locales: [Locale]
    let onStart: (String, Bool) -> Void
    let onPostpone: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedLocaleIdentifier: String
    @State private var deleteAudioAfterTranscription: Bool

    init(
        locales: [Locale],
        initialLocaleIdentifier: String,
        initiallyRetainsAudioAfterBatch: Bool,
        onStart: @escaping (String, Bool) -> Void,
        onPostpone: @escaping () -> Void
    ) {
        self.locales = locales
        self.onStart = onStart
        self.onPostpone = onPostpone
        _selectedLocaleIdentifier = State(initialValue: initialLocaleIdentifier)
        _deleteAudioAfterTranscription = State(initialValue: !initiallyRetainsAudioAfterBatch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.batchTranscriptionConfirmationTitle)
                .font(.headline)

            Text(L10n.batchTranscriptionConfirmationDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(L10n.language, selection: $selectedLocaleIdentifier) {
                ForEach(locales, id: \.identifier) { locale in
                    Text(displayName(for: locale)).tag(locale.identifier)
                }
            }
            .pickerStyle(.menu)

            Toggle(isOn: $deleteAudioAfterTranscription) {
                VStack(alignment: .leading) {
                    Text(L10n.deleteBatchAudioAfterTranscription)
                    Text(L10n.deleteBatchAudioAfterTranscriptionDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.generateSummaryAfterBatchTranscription) {
                VStack(alignment: .leading) {
                    Text(L10n.generateSummaryAfterBatchTranscription)
                    Text(L10n.generateSummaryAfterBatchTranscriptionDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Divider()

            HStack {
                Spacer()
                Button(L10n.later, action: onPostpone)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.startTranscription, action: startTranscription)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private func displayName(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier)
            ?? Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    private func startTranscription() {
        onStart(
            selectedLocaleIdentifier,
            !deleteAudioAfterTranscription
        )
    }
}
