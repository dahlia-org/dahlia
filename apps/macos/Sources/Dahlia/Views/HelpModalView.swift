import SwiftUI

/// The Help modal: illustrated explanations of how Dahlia works, one topic per sidebar item.
struct HelpModalView: View {
    enum Topic: CaseIterable, Hashable {
        case summary
        case providers
        case agents
        case dahliaMCP

        var title: String {
            switch self {
            case .summary: L10n.howItWorksSummaryTopic
            case .providers: L10n.howItWorksProvidersTopic
            case .agents: L10n.howItWorksAgentsTopic
            case .dahliaMCP: L10n.dahliaMCP
            }
        }

        var systemImage: String {
            switch self {
            case .summary: "doc.text"
            case .providers: "person.crop.circle"
            case .agents: "person.2"
            case .dahliaMCP: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    let onClose: () -> Void
    let onOpenSettings: (SettingsCategory) -> Void

    @State private var topic = Topic.summary

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Button(action: onClose) {
                    Color.black.opacity(0.16).ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHidden(true)

                card
                    .frame(
                        width: min(980, geometry.size.width - 48),
                        height: min(760, geometry.size.height - 48)
                    )
                    .dahliaModalSurface()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dahliaAppearance()
    }

    private var card: some View {
        VStack(spacing: 0) {
            DahliaWindowHeader(allowsWindowDragging: false) {
                Text(L10n.help)
                    .font(.dahliaHeadline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                DahliaWindowHeaderIconButton(label: L10n.close, systemImage: "xmark", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            HStack(spacing: 0) {
                List(selection: $topic) {
                    ForEach(Topic.allCases, id: \.self) { topic in
                        MainSidebarNavigationLabel(
                            title: topic.title,
                            systemImage: topic.systemImage,
                            isSelected: self.topic == topic
                        )
                        .tag(topic)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(width: 220)

                Divider()

                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 20) {
                        switch topic {
                        case .summary: SummaryExplainer()
                        case .providers: ProvidersExplainer()
                        case .agents: AgentsExplainer()
                        case .dahliaMCP: DahliaMCPExplainer(onOpenSettings: openDahliaMCPSettings)
                        }
                    }
                    .frame(width: 710, alignment: .leading)
                    .padding(24)
                }
                .id(topic)
            }
        }
    }

    private func openDahliaMCPSettings() {
        onClose()
        onOpenSettings(.dahliaMCP)
    }
}

// MARK: - Topics

private struct SummaryExplainer: View {
    var body: some View {
        ExplainerLead(L10n.howItWorksSummaryLead)

        ExplainerDiagram {
            HStack(spacing: 8) {
                VStack(spacing: 8) {
                    ExplainerStageLabel(L10n.howItWorksSummaryStageCapture)
                    VStack(spacing: 6) {
                        ExplainerNode(systemImage: "mic", title: L10n.microphone, caption: L10n.howItWorksSummaryMicCaption, tint: .blue)
                        ExplainerNode(
                            systemImage: "speaker.wave.2",
                            title: L10n.systemAudio,
                            caption: L10n.howItWorksSummarySystemAudioCaption,
                            tint: .blue
                        )
                    }
                    ExplainerNode(
                        systemImage: "camera.viewfinder",
                        title: L10n.screenshots,
                        caption: L10n.howItWorksSummaryScreenshotCaption,
                        tint: .orange
                    )
                    ExplainerNode(
                        systemImage: "note.text",
                        title: L10n.howItWorksSummaryContext,
                        caption: L10n.howItWorksSummaryContextCaption,
                        tint: .gray
                    )
                }
                VStack(spacing: 8) {
                    ExplainerStageLabel(" ")
                    ExplainerArrow().frame(maxHeight: .infinity)
                    ExplainerArrow().frame(height: 64)
                    ExplainerArrow().frame(height: 64)
                }
                VStack(spacing: 8) {
                    ExplainerStageLabel(L10n.howItWorksSummaryStagePrepare)
                    ExplainerNode(
                        systemImage: "waveform",
                        title: L10n.howItWorksSummaryTranscription,
                        caption: L10n.howItWorksSummaryTranscriptionCaption,
                        tint: .blue
                    )
                    .frame(maxHeight: .infinity)
                    ExplainerNode(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: L10n.howItWorksSummarySelection,
                        caption: L10n.howItWorksSummarySelectionCaption,
                        tint: .orange
                    )
                    ExplainerNode(
                        systemImage: "arrow.right.circle",
                        title: L10n.howItWorksSummaryAsIs,
                        caption: L10n.howItWorksSummaryAsIsCaption,
                        tint: .gray
                    )
                }
                ExplainerArrow()
                VStack(spacing: 8) {
                    ExplainerStageLabel(L10n.howItWorksSummaryStageGenerate)
                    Spacer(minLength: 0)
                    ExplainerNode(systemImage: "sparkles", title: L10n.howItWorksSummaryAI, caption: L10n.howItWorksSummaryAICaption, tint: .purple)
                    ExplainerArrow(axis: .vertical)
                    ExplainerNode(systemImage: "doc.text", title: L10n.summary, caption: L10n.howItWorksSummaryResultCaption, tint: .green)
                    Spacer(minLength: 0)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        ExplainerSection(title: L10n.howItWorksSummarySelectionTitle) {
            VStack(spacing: 6) {
                ExplainerFunnelStep(number: 1, text: L10n.howItWorksSummarySelectionCapture, widthFraction: 1)
                ExplainerFunnelStep(
                    number: 2,
                    text: L10n.howItWorksSummarySelectionCandidates(SummaryScreenshotSelection.candidateLimit),
                    widthFraction: 0.85
                )
                ExplainerFunnelStep(
                    number: 3,
                    text: L10n.howItWorksSummarySelectionModel(SummaryScreenshotSelection.limit),
                    widthFraction: 0.7
                )
                ExplainerArrow(axis: .vertical)
                ExplainerNode(systemImage: "sparkles", title: L10n.howItWorksSummaryAI, tint: .purple)
                    .frame(maxWidth: 200)
            }
            .frame(maxWidth: .infinity)
            ExplainerNote(L10n.howItWorksSummarySelectionFallback)
        }
    }
}

private struct ProvidersExplainer: View {
    private struct Provider: Identifiable {
        let name: String
        let caption: String
        let systemImage: String
        let capabilities: Set<Capability>
        var id: String { name }
    }

    private enum Capability: CaseIterable {
        case model
        case mcp
        case calendar
        case storage

        var title: String {
            switch self {
            case .model: L10n.howItWorksProvidersModel
            case .mcp: L10n.mcp
            case .calendar: L10n.howItWorksProvidersCalendar
            case .storage: L10n.howItWorksProvidersStorage
            }
        }

        var systemImage: String {
            switch self {
            case .model: "sparkles"
            case .mcp: "point.3.connected.trianglepath.dotted"
            case .calendar: "calendar"
            case .storage: "externaldrive"
            }
        }

        var usage: String {
            switch self {
            case .model: L10n.howItWorksProvidersModelUsage
            case .mcp: L10n.howItWorksProvidersMCPUsage
            case .calendar: L10n.howItWorksProvidersCalendarUsage
            case .storage: L10n.howItWorksProvidersStorageUsage
            }
        }

        var tint: Color {
            switch self {
            case .model: .purple
            case .mcp: .orange
            case .calendar: .red
            case .storage: .teal
            }
        }
    }

    private var providers: [Provider] {
        [
            Provider(
                name: "Databricks",
                caption: L10n.howItWorksProvidersDatabricksCaption,
                systemImage: "server.rack",
                capabilities: [.model, .mcp, .calendar]
            ),
            Provider(
                name: L10n.howItWorksProvidersDahlia,
                caption: L10n.howItWorksProvidersDahliaCaption,
                systemImage: "person.crop.circle",
                capabilities: [.model]
            ),
            Provider(name: "Google", caption: L10n.howItWorksProvidersGoogleCaption, systemImage: "globe", capabilities: [.calendar, .storage]),
            Provider(name: "ChatGPT · Anthropic", caption: L10n.howItWorksProvidersSubscriptionCaption, systemImage: "key", capabilities: [.model]),
        ]
    }

    var body: some View {
        ExplainerLead(L10n.howItWorksProvidersLead)

        ExplainerDiagram {
            HStack(alignment: .center, spacing: 10) {
                VStack(spacing: 8) {
                    ExplainerStageLabel(L10n.howItWorksProvidersTopic)
                    ForEach(providers) { provider in
                        HStack(spacing: 8) {
                            ExplainerNode(systemImage: provider.systemImage, title: provider.name, caption: provider.caption, tint: .blue)
                                .frame(width: 190)
                            HStack(spacing: 4) {
                                ForEach(Capability.allCases, id: \.self) { capability in
                                    ExplainerCapabilityDot(
                                        capability.systemImage,
                                        tint: capability.tint,
                                        isOn: provider.capabilities.contains(capability)
                                    )
                                    .help(capability.title)
                                }
                            }
                        }
                    }
                }
                ExplainerArrow()
                VStack(spacing: 8) {
                    ExplainerStageLabel(L10n.howItWorksProvidersUsageTitle)
                    ForEach(Capability.allCases, id: \.self) { capability in
                        ExplainerNode(systemImage: capability.systemImage, title: capability.title, caption: capability.usage, tint: capability.tint)
                    }
                }
            }
        }

        ExplainerSection(title: L10n.howItWorksProvidersWhereTitle) {
            ExplainerBody(L10n.howItWorksProvidersWhereBody)
            ExplainerNote(L10n.howItWorksProvidersSubscriptionNote)
        }
    }
}

private struct AgentsExplainer: View {
    var body: some View {
        ExplainerLead(L10n.howItWorksAgentsLead)

        ExplainerDiagram {
            HStack(spacing: 8) {
                VStack(spacing: 6) {
                    ExplainerStageLabel(L10n.howItWorksAgentsSources)
                    ExplainerNode(
                        systemImage: "envelope",
                        title: L10n.howItWorksAgentsConnectors,
                        caption: L10n.howItWorksAgentsConnectorsCaption,
                        tint: .orange
                    )
                    ExplainerNode(
                        systemImage: "calendar",
                        title: L10n.howItWorksProvidersCalendar,
                        caption: L10n.howItWorksAgentsCalendarCaption,
                        tint: .red
                    )
                    ExplainerNode(systemImage: "bell", title: L10n.howItWorksAgentsReminders, tint: .indigo)
                    ExplainerNode(
                        systemImage: "arrowshape.turn.up.left",
                        title: L10n.howItWorksAgentsAnswers,
                        caption: L10n.howItWorksAgentsAnswersCaption,
                        tint: .green
                    )
                }
                ExplainerArrow()
                VStack(spacing: 8) {
                    ExplainerStageLabel(" ")
                    ExplainerNode(systemImage: "tray.full", title: L10n.agentBotInboxTab, caption: L10n.howItWorksAgentsInboxCaption, tint: .blue)
                }
                ExplainerArrow()
                VStack(spacing: 8) {
                    ExplainerStageLabel(" ")
                    ExplainerNode(
                        systemImage: "person.crop.circle.badge.checkmark",
                        title: L10n.agentBots,
                        caption: L10n.howItWorksAgentsAgentCaption,
                        tint: .purple
                    )
                }
                VStack(spacing: 6) {
                    ExplainerStageLabel(" ")
                    ExplainerArrow(label: L10n.howItWorksAgentsDelegate)
                    ExplainerArrow(direction: .backward, label: L10n.howItWorksAgentsResult)
                    Spacer().frame(height: 24)
                    ExplainerArrow(label: L10n.howItWorksAgentsAsk)
                }
                VStack(spacing: 8) {
                    ExplainerStageLabel(" ")
                    ExplainerNode(systemImage: "checklist", title: L10n.agentBotTasks, caption: L10n.howItWorksAgentsTaskCaption, tint: .teal)
                    ExplainerNode(
                        systemImage: "person.fill.questionmark",
                        title: L10n.agentBotInbox,
                        caption: L10n.howItWorksAgentsConfirmationCaption,
                        tint: .green
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        ExplainerSection(title: L10n.howItWorksAgentsRoutingTitle) {
            HStack(spacing: 12) {
                ExplainerNode(
                    systemImage: "arrow.triangle.branch",
                    title: L10n.howItWorksAgentsAgentThread,
                    caption: L10n.howItWorksAgentsAgentThreadCaption,
                    tint: .purple
                )
                ExplainerArrow(label: L10n.howItWorksAgentsDelegate)
                VStack(spacing: 6) {
                    ExplainerNode(
                        systemImage: "bubble.left.and.text.bubble.right",
                        title: L10n.howItWorksAgentsWorkThread,
                        caption: L10n.howItWorksAgentsWorkThreadCaption,
                        tint: .teal
                    )
                    ExplainerNode(systemImage: "bubble.left.and.text.bubble.right", title: L10n.howItWorksAgentsWorkThread, tint: .teal)
                        .opacity(0.6)
                }
            }
            ExplainerBody(L10n.howItWorksAgentsRoutingBody)
        }

        ExplainerSection(title: L10n.agentBotTasks) {
            HStack(spacing: 8) {
                ExplainerChip(L10n.agentBotTaskStatus("active"), tint: .blue)
                ExplainerArrow()
                VStack(alignment: .leading, spacing: 6) {
                    ExplainerChip(L10n.agentBotTaskStatus("done"), tint: .green)
                    ExplainerChip(L10n.agentBotTaskStatus("dismissed"), tint: .gray)
                }
            }
            ExplainerBody(L10n.howItWorksAgentsTasksBody)
        }

        ExplainerSection(title: L10n.agentBotInbox) {
            HStack(spacing: 8) {
                ExplainerChip(L10n.agentBotKindQuestion, tint: .green)
                ExplainerChip(L10n.agentBotKindReport, tint: .green)
                ExplainerChip(L10n.agentBotKindSuggestion, tint: .green)
                ExplainerArrow()
                ExplainerChip(L10n.agentBotAnswerSend, tint: .blue)
                ExplainerChip(L10n.agentBotAccept, tint: .blue)
                ExplainerChip(L10n.agentBotDismiss, tint: .blue)
                ExplainerChip(L10n.agentBotSeen, tint: .blue)
            }
            ExplainerBody(L10n.howItWorksAgentsConfirmationBody)
            ExplainerNote(L10n.howItWorksAgentsNote)
        }
    }
}

private struct DahliaMCPExplainer: View {
    let onOpenSettings: () -> Void

    var body: some View {
        ExplainerLead(L10n.howItWorksMCPLead)

        ExplainerDiagram {
            HStack(spacing: 8) {
                VStack(spacing: 8) {
                    ExplainerStageLabel(L10n.howItWorksMCPClients)
                    ExplainerNode(systemImage: "terminal", title: "Claude Code · Codex", caption: L10n.howItWorksMCPClientsCaption, tint: .blue)
                    ExplainerNode(
                        systemImage: "bubble.left.and.bubble.right",
                        title: L10n.howItWorksMCPDahliaChat,
                        caption: L10n.howItWorksMCPDahliaChatCaption,
                        tint: .purple
                    )
                }
                ExplainerArrow(label: "MCP")
                VStack(spacing: 8) {
                    ExplainerStageLabel(L10n.howItWorksMCPOnMac)
                    ExplainerNode(image: mcpLogo, title: "dahlia-mcp", caption: L10n.howItWorksMCPHelperCaption, tint: .orange)
                }
                ExplainerArrow(label: L10n.howItWorksMCPRead)
                VStack(spacing: 6) {
                    ExplainerStageLabel(L10n.howItWorksMCPData)
                    ExplainerNode(
                        systemImage: "calendar",
                        title: L10n.howItWorksMCPMeetings,
                        caption: L10n.howItWorksMCPMeetingsCaption,
                        tint: .green
                    )
                    ExplainerNode(systemImage: "photo.on.rectangle", title: L10n.screenshots, tint: .green)
                    ExplainerNode(systemImage: "folder", title: L10n.howItWorksMCPProjects, tint: .green)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        ExplainerSection(title: L10n.howItWorksMCPAccessTitle) {
            HStack(spacing: 8) {
                ExplainerChip(L10n.howItWorksMCPReadOnly, tint: .green)
                ExplainerArrow(label: L10n.howItWorksMCPOptIn)
                ExplainerChip(L10n.howItWorksMCPWrite, tint: .orange)
            }
            ExplainerBody(L10n.howItWorksMCPAccessBody)
            ExplainerNote(L10n.howItWorksMCPNotShared)
        }

        ExplainerSection(title: L10n.howItWorksMCPSetupTitle) {
            ExplainerBody(L10n.howItWorksMCPSetupBody)
            Button(L10n.howItWorksMCPOpenSettings, action: onOpenSettings)
                .buttonStyle(.dahlia(.primary))
        }
    }

    private var mcpLogo: Image {
        if let icon = Bundle.appModule.image(forResource: "MCPLogo") {
            Image(nsImage: icon).renderingMode(.template)
        } else {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
    }
}

// MARK: - Diagram vocabulary

private struct ExplainerLead: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.dahliaTitle3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExplainerBody: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.dahliaBody)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExplainerNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.dahliaSecondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExplainerSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.dahliaHeadline)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct ExplainerDiagram<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(DahliaDesign.contentHighlightColor.opacity(0.5), in: .rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
    }
}

private struct ExplainerStageLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.dahliaSectionHeader)
            .foregroundStyle(.secondary)
            .accessibilityHidden(text.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

private struct ExplainerNode: View {
    let image: Image
    let title: String
    var caption: String?
    let tint: Color

    init(systemImage: String, title: String, caption: String? = nil, tint: Color) {
        self.init(image: Image(systemName: systemImage), title: title, caption: caption, tint: tint)
    }

    init(image: Image, title: String, caption: String? = nil, tint: Color) {
        self.image = image
        self.title = title
        self.caption = caption
        self.tint = tint
    }

    private var iconSize: CGFloat { DahliaTypography.size(offset: 6) }

    var body: some View {
        VStack(spacing: 4) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.dahliaHeadline)
            if let caption {
                Text(caption)
                    .font(.dahliaSecondary)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: DahliaDesign.Card.compactCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DahliaDesign.Card.compactCornerRadius)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ExplainerArrow: View {
    enum Direction { case forward, backward }

    var axis: Axis = .horizontal
    var direction: Direction = .forward
    var label: String?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.dahliaBody)
                .foregroundStyle(.secondary)
            if let label {
                Text(label)
                    .font(.dahliaSecondary)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .accessibilityHidden(label == nil)
    }

    private var symbol: String {
        switch (axis, direction) {
        case (.horizontal, .forward): "arrow.right"
        case (.horizontal, .backward): "arrow.left"
        case (.vertical, .forward): "arrow.down"
        case (.vertical, .backward): "arrow.up"
        }
    }
}

private struct ExplainerFunnelStep: View {
    let number: Int
    let text: String
    let widthFraction: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number.formatted())
                .font(.dahliaHeadline)
                .foregroundStyle(.orange)
            Text(text)
                .font(.dahliaBody)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.1 + 0.08 * Double(number)), in: .rect(cornerRadius: DahliaDesign.Card.compactCornerRadius))
        .frame(maxWidth: 640 * widthFraction)
    }
}

private struct ExplainerCapabilityDot: View {
    let systemImage: String
    let tint: Color
    let isOn: Bool

    init(_ systemImage: String, tint: Color, isOn: Bool) {
        self.systemImage = systemImage
        self.tint = tint
        self.isOn = isOn
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.dahliaSecondary)
            .foregroundStyle(isOn ? tint : Color.secondary.opacity(0.3))
            .frame(width: 24, height: 24)
            .background(isOn ? tint.opacity(0.15) : .clear, in: .circle)
            .overlay { Circle().strokeBorder(isOn ? tint.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1) }
            .accessibilityHidden(!isOn)
    }
}

private struct ExplainerChip: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.dahliaSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: .capsule)
            .overlay { Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1) }
    }
}
