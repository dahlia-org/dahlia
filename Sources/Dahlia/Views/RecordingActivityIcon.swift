import SwiftUI

struct RecordingActivityIcon: View {
    let mode: TranscriptionMode

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Image(systemName: systemImage)
            .font(.body)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.red)
            .symbolEffect(
                .breathe.pulse,
                options: .repeat(.periodic(delay: 0.8)).speed(0.7),
                isActive: !accessibilityReduceMotion
            )
            .frame(width: 18)
            .accessibilityHidden(true)
    }

    private var systemImage: String {
        mode == .realtime ? "waveform.badge.microphone" : "record.circle.fill"
    }
}
