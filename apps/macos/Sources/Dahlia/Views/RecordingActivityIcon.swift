import SwiftUI

struct RecordingActivityIcon: View {
    let mode: TranscriptionMode

    var body: some View {
        Image(systemName: systemImage)
            .font(.body)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.red)
            .frame(width: 18)
            .accessibilityHidden(true)
    }

    private var systemImage: String {
        mode == .realtime ? "waveform.badge.microphone" : "record.circle.fill"
    }
}
