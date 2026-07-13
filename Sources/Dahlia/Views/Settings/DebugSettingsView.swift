import SwiftUI

struct DebugSettingsView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Button(
                    L10n.openAudioRecognitionTest,
                    systemImage: "waveform.and.mic",
                    action: openAudioRecognitionTest
                )
            } header: {
                Text(L10n.audioRecognitionTest)
            } footer: {
                Text(L10n.audioRecognitionTestDescription)
            }

            Section {
                Button(
                    L10n.openApplicationLogs,
                    systemImage: "doc.text.magnifyingglass",
                    action: openApplicationLogs
                )
            } header: {
                Text(L10n.applicationLogs)
            } footer: {
                Text(L10n.applicationLogsDescription)
            }
        }
        .formStyle(.grouped)
    }

    private func openAudioRecognitionTest() {
        openWindow(id: WindowID.audioRecognitionTest)
    }

    private func openApplicationLogs() {
        openWindow(id: WindowID.applicationLogs)
    }
}
