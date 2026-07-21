import SwiftUI

struct BatchTranscriptionConfirmationView: View {
    let locales: [Locale]
    let onStart: (BatchTranscriptionLanguageSelection, Bool) -> Void
    let onPostpone: () -> Void

    @State private var languageSelection: BatchTranscriptionLanguageSelection
    @State private var deleteAudioAfterTranscription: Bool

    init(
        locales: [Locale],
        initialLanguageSelection: BatchTranscriptionLanguageSelection,
        initiallyRetainsAudioAfterBatch: Bool,
        onStart: @escaping (BatchTranscriptionLanguageSelection, Bool) -> Void,
        onPostpone: @escaping () -> Void
    ) {
        self.locales = locales
        self.onStart = onStart
        self.onPostpone = onPostpone
        _languageSelection = State(initialValue: initialLanguageSelection)
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
                languageSelection: $languageSelection,
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
            languageSelection,
            !deleteAudioAfterTranscription
        )
    }
}
