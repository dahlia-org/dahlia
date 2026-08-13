import DahliaRuntimeSupport
import SwiftUI

struct SummaryTranscriptReferenceChip: View {
    let reference: TranscriptReference
    let transcriptText: String?
    let allowsPopover: Bool

    @State private var isTranscriptPopoverPresented = false

    var body: some View {
        Text(reference.time)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, DahliaDesign.timestampChipHorizontalPadding)
            .padding(.vertical, DahliaDesign.timestampChipVerticalPadding)
            .background(Color.primary.opacity(DahliaDesign.timestampChipBackgroundOpacity), in: Capsule())
            .onHover(perform: updatePopoverPresentation)
            .onChange(of: allowsPopover) {
                guard !allowsPopover else { return }
                isTranscriptPopoverPresented = false
            }
            .popover(isPresented: $isTranscriptPopoverPresented, arrowEdge: .bottom) {
                if let transcriptText = transcriptText?.nilIfBlank {
                    Text(transcriptText)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding(10)
                }
            }
    }

    private func updatePopoverPresentation(isHovering: Bool) {
        isTranscriptPopoverPresented = allowsPopover
            && isHovering
            && transcriptText?.nilIfBlank != nil
    }
}
