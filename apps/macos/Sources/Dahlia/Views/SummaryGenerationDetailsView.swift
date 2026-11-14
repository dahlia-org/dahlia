import DahliaRuntimeSupport
import SwiftUI

struct SummaryGenerationDetailsView: View {
    let metadata: SummaryMetadata?
    @State private var isPresented = false
    @State private var isHovered = false

    private var modelLabel: String {
        let model = metadata?.response?.model ?? metadata?.request.model ?? "—"
        guard let effort = metadata?.response?.reasoning?.effort ?? metadata?.request.reasoning?.effort else { return model }
        return "\(model) (\(effort))"
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(modelLabel, systemImage: "brain")
                .font(.dahliaSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .dahliaChipSurface(isHovered: isHovered, tint: .clear)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
        .help(L10n.summaryGenerationDetails)
        .accessibilityLabel(L10n.summaryGenerationDetails)
        .accessibilityValue(modelLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DahliaDesign.blockSpacing) {
                Text(L10n.summaryGenerationDetails).font(.dahliaHeadline)
                if let metadata {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow { Text(L10n.summaryRequestedModel)
                            Text(metadata.request.model ?? "—")
                        }
                        GridRow { Text(L10n.summaryResponseModel)
                            Text(metadata.response?.model ?? "—")
                        }
                        GridRow { Text(L10n.reasoningEffort)
                            Text(metadata.response?.reasoning?.effort ?? metadata.request.reasoning?.effort ?? "—")
                        }
                        GridRow {
                            Text(L10n.summaryStyle)
                            Text(metadata.detailLevel.map { SummaryDetailLevel(rawValue: $0)?.displayName ?? $0 } ?? "—")
                        }
                    }
                    .textSelection(.enabled)
                } else {
                    Text(L10n.summaryGenerationDetailsUnavailable)
                }
            }
            .font(.dahliaSecondary)
            .padding()
        }
    }
}
