import SwiftUI

struct DebugSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var isAudioProcessMonitorRunning = false

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.codexVersion, value: CodexBundle.version)
            }

            Section {
                Button(
                    isAudioProcessMonitorRunning ? L10n.stopAudioProcessActivityMonitor : L10n.startAudioProcessActivityMonitor,
                    systemImage: isAudioProcessMonitorRunning ? "stop.circle" : "waveform.badge.magnifyingglass",
                    action: toggleAudioProcessActivityMonitor
                )
            } header: {
                Text(L10n.audioProcessActivityMonitor)
            } footer: {
                Text(L10n.audioProcessActivityMonitorDescription)
            }

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
        .task {
            isAudioProcessMonitorRunning = await AudioProcessActivityMonitor.shared.isMonitoring()
        }
    }

    private func openAudioRecognitionTest() {
        openWindow(id: WindowID.audioRecognitionTest)
    }

    private func openApplicationLogs() {
        openWindow(id: WindowID.applicationLogs)
    }

    private func toggleAudioProcessActivityMonitor() {
        Task {
            if await AudioProcessActivityMonitor.shared.isMonitoring() {
                await AudioProcessActivityMonitor.shared.stopMonitoring()
            } else {
                await AudioProcessActivityMonitor.shared.startMonitoring()
            }
            isAudioProcessMonitorRunning = await AudioProcessActivityMonitor.shared.isMonitoring()
        }
    }
}
