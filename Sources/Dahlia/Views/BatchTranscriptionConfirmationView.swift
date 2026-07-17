import SwiftUI

struct BatchTranscriptionConfirmationView: View {
    let locales: [Locale]
    let onStart: (String, Bool) -> Void
    let onPostpone: () -> Void

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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.batchTranscriptionConfirmationTitle)
                    .font(.headline)

                Text(L10n.batchTranscriptionConfirmationDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            BatchTranscriptionOptionsForm(
                locales: locales,
                selectedLocaleIdentifier: $selectedLocaleIdentifier,
                deleteAudioAfterTranscription: $deleteAudioAfterTranscription
            )

            Divider()

            HStack {
                Spacer()
                Button(L10n.later, action: onPostpone)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.startTranscription, action: startTranscription)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 520, minHeight: 440, idealHeight: 500)
    }

    private func startTranscription() {
        onStart(
            selectedLocaleIdentifier,
            !deleteAudioAfterTranscription
        )
    }
}
