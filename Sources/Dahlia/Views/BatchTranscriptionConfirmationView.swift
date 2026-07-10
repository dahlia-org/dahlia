import SwiftUI

struct BatchTranscriptionConfirmationView: View {
    let locales: [Locale]
    let onStart: (String) -> Void
    let onPostpone: () -> Void

    @State private var selectedLocaleIdentifier: String

    init(
        locales: [Locale],
        initialLocaleIdentifier: String,
        onStart: @escaping (String) -> Void,
        onPostpone: @escaping () -> Void
    ) {
        self.locales = locales
        self.onStart = onStart
        self.onPostpone = onPostpone
        _selectedLocaleIdentifier = State(initialValue: initialLocaleIdentifier)
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

            Divider()

            HStack {
                Spacer()
                Button(L10n.later, action: onPostpone)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.startTranscription) {
                    onStart(selectedLocaleIdentifier)
                }
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
}
