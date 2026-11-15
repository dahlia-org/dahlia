import SwiftUI

/// Select a recognition step or the workspace region to show its settings below.
struct MeetingProcessingFlow: View {
    enum Node: Hashable, Sendable {
        case audio, video, liveTranscription, transcription, screenshots, imageAnalysis, summary, workspace

        var title: String {
            switch self {
            case .audio: L10n.meetingProcessingAudio
            case .video: L10n.meetingProcessingVideo
            case .liveTranscription: L10n.meetingProcessingLiveTranscription
            case .transcription: L10n.transcription
            case .screenshots: L10n.meetingProcessingScreenshotCapture
            case .imageAnalysis: L10n.meetingProcessingImageRecognition
            case .summary: L10n.meetingProcessingSummaryGeneration
            case .workspace: L10n.workspaceSettings
            }
        }

        var symbol: String {
            switch self {
            case .audio: "waveform.badge.microphone"
            case .video: "video"
            case .liveTranscription: "captions.bubble"
            case .transcription: "text.alignleft"
            case .screenshots: "camera.viewfinder"
            case .imageAnalysis: "text.below.photo"
            case .summary: "sparkles"
            case .workspace: "square.stack.3d.up"
            }
        }
    }

    @Binding var selection: Node

    private let connections: [(Node, Node)] = [
        (.audio, .liveTranscription), (.audio, .transcription),
        (.video, .screenshots), (.screenshots, .imageAnalysis), (.transcription, .summary),
    ]

    var body: some View {
        Grid(horizontalSpacing: 40, verticalSpacing: 20) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                stage(.liveTranscription, detail: L10n.settingsDuringRecording)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    .allowsHitTesting(false)
            }
            GridRow {
                source(.audio)
                stage(.transcription, detail: L10n.settingsAfterRecording)
                workspaceCard(.summary)
            }
            GridRow {
                source(.video)
                stage(.screenshots, detail: L10n.settingsDuringRecording)
                workspaceCard(.imageAnalysis)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .backgroundPreferenceValue(MeetingProcessingFlowBounds.self) { bounds in
            GeometryReader { geometry in
                if let summary = bounds[.summary], let imageAnalysis = bounds[.imageAnalysis] {
                    let cards = geometry[summary].union(geometry[imageAnalysis])
                    workspaceSettings(cards: cards)
                        .position(x: cards.midX, y: cards.midY - 20)
                }
            }
        }
        .overlayPreferenceValue(MeetingProcessingFlowBounds.self) { bounds in
            GeometryReader { geometry in
                Path { path in
                    for (source, destination) in connections {
                        if let sourceBounds = bounds[source], let destinationBounds = bounds[destination] {
                            let start = geometry[sourceBounds]
                            let end = geometry[destinationBounds]
                            let destinationX = end.minX
                            path.move(to: CGPoint(x: start.maxX + 4, y: start.midY))
                            if destination == .liveTranscription {
                                let middleX = (start.maxX + destinationX) / 2
                                path.addLine(to: CGPoint(x: middleX, y: start.midY))
                                path.addLine(to: CGPoint(x: middleX, y: end.midY))
                            }
                            path.addLine(to: CGPoint(x: destinationX - 4, y: end.midY))
                            path.move(to: CGPoint(x: destinationX - 9, y: end.midY - 4))
                            path.addLine(to: CGPoint(x: destinationX - 4, y: end.midY))
                            path.addLine(to: CGPoint(x: destinationX - 9, y: end.midY + 4))
                        }
                    }
                }
                .stroke(DahliaDesign.secondaryTextColor, style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    private func workspaceSettings(cards: CGRect) -> some View {
        Button {
            selection = .workspace
        } label: {
            VStack(alignment: .leading, spacing: 20) {
                Label(L10n.workspaceSettings, systemImage: Node.workspace.symbol)
                    .font(.dahliaHeadline)
                    .foregroundStyle(DahliaDesign.primaryTextColor)
                Spacer(minLength: 0)
            }
            .frame(width: cards.width, height: cards.height + 40, alignment: .topLeading)
            .padding(8)
            .contentShape(.rect)
        }
        .buttonStyle(.dahlia())
        .overlay {
            RoundedRectangle(cornerRadius: DahliaDesign.Button.cornerRadius)
                .strokeBorder(
                    selection == .workspace ? Color.accentColor : Color.primary.opacity(0.25),
                    lineWidth: selection == .workspace ? 2 : 1
                )
                .allowsHitTesting(false)
        }
        .accessibilityAddTraits(selection == .workspace ? [.isSelected] : [])
        .accessibilityHint(L10n.meetingProcessingFlowHint)
    }

    private func workspaceCard(_ node: Node) -> some View {
        source(node)
            .foregroundStyle(DahliaDesign.primaryTextColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: DahliaDesign.Card.compactCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DahliaDesign.Card.compactCornerRadius)
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
            }
            .anchorPreference(key: MeetingProcessingFlowBounds.self, value: .bounds) { [node: $0] }
            .allowsHitTesting(false)
    }

    private func source(_ node: Node) -> some View {
        Label(node.title, systemImage: node.symbol)
            .font(.dahliaBody)
            .fixedSize(horizontal: false, vertical: true)
            .anchorPreference(key: MeetingProcessingFlowBounds.self, value: .bounds) { [node: $0] }
    }

    private func stage(_ node: Node, detail: String) -> some View {
        Button {
            selection = node
        } label: {
            HStack(spacing: 6) {
                Label(node.title, systemImage: node.symbol)
                    .font(.dahliaBody)
                    .fixedSize()
                Text(detail)
                    .font(.dahliaSecondary)
                    .foregroundStyle(selection == node ? .white : DahliaDesign.primaryTextColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(selection == node ? Color.white.opacity(0.2) : Color.primary.opacity(0.08), in: .capsule)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.dahlia(selection == node ? .primary : .secondary))
        .accessibilityAddTraits(selection == node ? [.isSelected] : [])
        .accessibilityHint(L10n.meetingProcessingFlowHint)
        .anchorPreference(key: MeetingProcessingFlowBounds.self, value: .bounds) { [node: $0] }
    }
}
