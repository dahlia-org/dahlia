import SwiftUI

/// The Help modal: illustrated explanations of how Dahlia works, one topic per sidebar item.
struct HelpModalView: View {
    enum Topic: CaseIterable, Hashable {
        case summary
        case providers
        case agents
        case modes
        case dahliaMCP

        var title: String {
            switch self {
            case .summary: L10n.howItWorksSummaryTopic
            case .providers: L10n.howItWorksProvidersTopic
            case .agents: L10n.howItWorksAgentsTopic
            case .modes: L10n.howItWorksModesTopic
            case .dahliaMCP: L10n.dahliaMCP
            }
        }

        var systemImage: String {
            switch self {
            case .summary: "doc.text"
            case .providers: "person.crop.circle"
            case .agents: "person.2"
            case .modes: "tablecells"
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

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch topic {
                        case .summary: SummaryExplainer()
                        case .providers: ProvidersExplainer()
                        case .agents: AgentsExplainer()
                        case .modes: ModesExplainer()
                        case .dahliaMCP: DahliaMCPExplainer(onOpenSettings: openDahliaMCPSettings)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            ExplainerDiagram {
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
            }
            ExplainerBody(L10n.howItWorksAgentsRoutingBody)
        }

        ExplainerSection(title: L10n.agentBotTasks) {
            ExplainerDiagram {
                HStack(spacing: 8) {
                    ExplainerChip(L10n.agentBotTaskStatus("active"), tint: .blue)
                    ExplainerArrow()
                    VStack(alignment: .leading, spacing: 6) {
                        ExplainerChip(L10n.agentBotTaskStatus("done"), tint: .green)
                        ExplainerChip(L10n.agentBotTaskStatus("dismissed"), tint: .gray)
                    }
                }
            }
            ExplainerBody(L10n.howItWorksAgentsTasksBody)
        }

        ExplainerSection(title: L10n.agentBotInbox) {
            ExplainerDiagram {
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
            }
            ExplainerBody(L10n.howItWorksAgentsConfirmationBody)
            ExplainerNote(L10n.howItWorksAgentsNote)
        }
    }
}

/// What each way the AI runs can use. Keep the matrix aligned with
/// `PiExecutionProfile`, `PiChatService`'s launch arguments, and `dahlia.ts`'s tool policy.
enum HelpModesMatrix {
    enum Access { case full, partial, none }

    struct Row {
        let title: String
        let caption: String
        let systemImage: String
        let tint: Color
        let access: [Access]
    }

    static var capabilities: [(title: String, systemImage: String)] {
        [
            (L10n.howItWorksModesRowFiles, "terminal"),
            (L10n.howItWorksModesRowDahlia, "calendar"),
            (L10n.howItWorksModesRowConnectors, "point.3.connected.trianglepath.dotted"),
            (L10n.howItWorksModesRowWeb, "globe"),
            (L10n.howItWorksModesRowSkills, "book"),
            (L10n.howItWorksModesRowMemory, "brain"),
            (L10n.howItWorksModesRowThreads, "bubble.left.and.text.bubble.right"),
            (L10n.howItWorksModesRowApproval, "square.and.arrow.up"),
        ]
    }

    static var rows: [Row] {
        [
            Row(
                title: L10n.howItWorksModesRowChat,
                caption: L10n.howItWorksModesRowChatCaption,
                systemImage: "bubble.left.and.text.bubble.right",
                tint: .teal,
                access: [.full, .full, .full, .full, .full, .full, .partial, .full]
            ),
            Row(
                title: L10n.howItWorksModesColumnAgent,
                caption: L10n.howItWorksModesRowAgentCaption,
                systemImage: "person.crop.circle.badge.checkmark",
                tint: .purple,
                access: [.partial, .partial, .none, .none, .none, .partial, .full, .none]
            ),
            Row(
                title: L10n.howItWorksModesColumnIntake,
                caption: L10n.howItWorksModesRowIntakeCaption,
                systemImage: "tray.and.arrow.down",
                tint: .orange,
                access: [.none, .none, .partial, .none, .partial, .none, .none, .none]
            ),
            Row(
                title: L10n.howItWorksModesColumnScheduled,
                caption: L10n.howItWorksModesRowScheduledCaption,
                systemImage: "clock",
                tint: .indigo,
                access: [.partial, .partial, .partial, .none, .partial, .partial, .none, .none]
            ),
        ]
    }
}

private struct ModesExplainer: View {
    private let capabilityWidth: CGFloat = 58

    var body: some View {
        ExplainerLead(L10n.howItWorksModesLead)

        ExplainerDiagram { ModesMap() }
        ExplainerBody(L10n.howItWorksModesMapBody)

        ExplainerSection(title: L10n.howItWorksModesMatrixTitle) {
            ExplainerDiagram {
                Grid(alignment: .leading, horizontalSpacing: 2, verticalSpacing: 10) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        ForEach(HelpModesMatrix.capabilities, id: \.title) { capability in
                            VStack(spacing: 4) {
                                Image(systemName: capability.systemImage)
                                Text(capability.title)
                                    .font(.dahliaSecondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(.secondary)
                            .frame(width: capabilityWidth)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                        }
                    }
                    ForEach(HelpModesMatrix.rows, id: \.title) { row in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: row.systemImage)
                                    .foregroundStyle(row.tint)
                                    .frame(width: DahliaTypography.size(offset: 6))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(.dahliaHeadline)
                                    Text(row.caption)
                                        .font(.dahliaSecondary)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            ForEach(row.access.indices, id: \.self) { index in
                                let capability = HelpModesMatrix.capabilities[index]
                                ExplainerCapabilityDot(
                                    capability.systemImage,
                                    tint: row.tint,
                                    isOn: row.access[index] != .none,
                                    isPartial: row.access[index] == .partial
                                )
                                .help(capability.title)
                                .frame(width: capabilityWidth)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(capability.title): \(accessTitle(row.access[index]))")
                                .gridCellAnchor(.center)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                ForEach([HelpModesMatrix.Access.full, .partial, .none], id: \.self) { access in
                    HStack(spacing: 6) {
                        ExplainerCapabilityDot("checkmark", tint: .teal, isOn: access != .none, isPartial: access == .partial)
                            .accessibilityHidden(true)
                        Text(accessTitle(access))
                            .font(.dahliaSecondary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        ExplainerSection(title: L10n.howItWorksModesOtherTitle) {
            ExplainerBody(L10n.howItWorksModesOtherBody)
            ExplainerNote(L10n.howItWorksModesNote)
        }
    }

    private func accessTitle(_ access: HelpModesMatrix.Access) -> String {
        switch access {
        case .full: L10n.howItWorksModesAccessFull
        case .partial: L10n.howItWorksModesAccessPartial
        case .none: L10n.howItWorksModesAccessNone
        }
    }
}

/// Who can touch what: the outside world on top, Dahlia's own data below, and each way the AI runs in between.
/// A line is access (its heads show which way data moves); no line means no access.
private struct ModesMap: View {
    var body: some View {
        VStack(spacing: 0) {
            ExplainerBand(
                systemImage: "globe",
                title: L10n.howItWorksModesMapExternal,
                caption: L10n.howItWorksModesMapExternalCaption,
                tint: .orange
            )
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ExplainerLink(towardTop: false, label: L10n.howItWorksModesMapRead)
                    empty
                    ExplainerLink(towardTop: false, label: L10n.howItWorksModesMapReadOne)
                    empty
                    empty
                    empty
                    ExplainerLink(towardTop: true, towardBottom: true, label: L10n.howItWorksModesMapReadWrite)
                }
                GridRow {
                    node("clock", L10n.howItWorksModesColumnScheduled, L10n.howItWorksModesMapScheduledCaption, .indigo)
                    Color.clear.frame(width: 8, height: 1)
                    node("tray.and.arrow.down", L10n.howItWorksModesColumnIntake, L10n.howItWorksModesMapIntakeCaption, .orange)
                    ExplainerFlow(forward: L10n.howItWorksModesMapEvent)
                    node(
                        "person.crop.circle.badge.checkmark",
                        L10n.howItWorksModesColumnAgent,
                        L10n.howItWorksModesMapAgentCaption,
                        .purple,
                        width: 112
                    )
                    ExplainerFlow(forward: L10n.howItWorksModesMapTask, backward: L10n.howItWorksModesMapResult)
                    ExplainerGroup(title: L10n.howItWorksModesMapSame, footer: L10n.howItWorksModesMapDifferences, tint: .teal) {
                        node("bubble.left.and.text.bubble.right", L10n.howItWorksModesMapWorker, L10n.howItWorksModesMapWorkerCaption, .teal)
                        node("bubble.left.and.text.bubble.right", L10n.howItWorksModesMapChat, L10n.howItWorksModesMapChatCaption, .teal)
                    }
                }
                GridRow {
                    ExplainerLink(towardTop: true, label: L10n.howItWorksModesMapRead)
                    empty
                    empty
                    empty
                    ExplainerLink(towardTop: true, label: L10n.howItWorksModesMapRead)
                    empty
                    ExplainerLink(towardTop: true, towardBottom: true, label: L10n.howItWorksModesMapReadWrite)
                }
            }
            ExplainerBand(systemImage: "calendar", title: "Dahlia", caption: L10n.howItWorksModesMapDahliaCaption, tint: .green)
        }
    }

    private var empty: some View {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
    }

    private func node(_ systemImage: String, _ title: String, _ caption: String, _ tint: Color, width: CGFloat = 100) -> some View {
        ExplainerNode(systemImage: systemImage, title: title, caption: caption, tint: tint)
            .frame(width: width)
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
            ExplainerDiagram {
                HStack(spacing: 8) {
                    ExplainerChip(L10n.howItWorksMCPReadOnly, tint: .green)
                    ExplainerArrow(label: L10n.howItWorksMCPOptIn)
                    ExplainerChip(L10n.howItWorksMCPWrite, tint: .orange)
                }
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
        ScrollView(.horizontal) {
            content
                .frame(width: 678)
                .padding(16)
        }
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
    /// Drawn hollow with a dashed ring: usable only in part, such as read only.
    let isPartial: Bool

    init(_ systemImage: String, tint: Color, isOn: Bool, isPartial: Bool = false) {
        self.systemImage = systemImage
        self.tint = tint
        self.isOn = isOn
        self.isPartial = isPartial
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.dahliaSecondary)
            .foregroundStyle(isOn ? tint : Color.secondary.opacity(0.3))
            .frame(width: 24, height: 24)
            .background(isOn && !isPartial ? tint.opacity(0.15) : .clear, in: .circle)
            .overlay {
                Circle().strokeBorder(
                    isOn ? tint.opacity(isPartial ? 0.7 : 0.4) : Color.secondary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1, dash: isPartial ? [3, 2] : [])
                )
            }
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

/// A wide strip for a place many nodes reach, such as the outside world or Dahlia's own data.
private struct ExplainerBand: View {
    let systemImage: String
    let title: String
    let caption: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title).font(.dahliaHeadline)
            Text(caption)
                .font(.dahliaSecondary)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: DahliaDesign.Card.compactCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DahliaDesign.Card.compactCornerRadius)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A frame around nodes that behave the same, with what sets them apart underneath.
private struct ExplainerGroup<Content: View>: View {
    let title: String
    let footer: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.dahliaSectionHeader)
                .foregroundStyle(tint)
                .fixedSize()
            HStack(spacing: 8) { content }
                .fixedSize(horizontal: false, vertical: true)
            ExplainerChip(footer, tint: tint)
                .fixedSize()
        }
        .padding(8)
        .background(tint.opacity(0.05), in: .rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                .strokeBorder(tint.opacity(0.5), style: StrokeStyle(lineWidth: 1.5))
        }
    }
}

/// A vertical access line between a node and the bands above and below it. Heads point where data goes.
private struct ExplainerLink: View {
    var towardTop: Bool
    var towardBottom = false
    let label: String

    init(towardTop: Bool, towardBottom: Bool = false, label: String) {
        self.towardTop = towardTop
        self.towardBottom = towardBottom || !towardTop
        self.label = label
    }

    var body: some View {
        ExplainerLine(axis: .vertical, startHead: towardTop, endHead: towardBottom)
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: 12, height: 40)
            .overlay(alignment: .leading) {
                Text(label)
                    .font(.dahliaSecondary)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: 16)
            }
            .accessibilityElement()
            .accessibilityLabel(label)
    }
}

/// A horizontal hand-off that stretches across the gap, labelled with what it carries.
private struct ExplainerFlow: View {
    let forward: String
    var backward: String?

    var body: some View {
        VStack(spacing: 6) {
            line(forward, startHead: false)
            if let backward { line(backward, startHead: true) }
        }
        .padding(.horizontal, 6)
        .frame(width: 68)
    }

    private func line(_ label: String, startHead: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.dahliaSecondary)
                .foregroundStyle(.secondary)
                .fixedSize()
            ExplainerLine(axis: .horizontal, startHead: startHead, endHead: !startHead)
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

private struct ExplainerLine: Shape {
    let axis: Axis
    var startHead = false
    var endHead = true

    func path(in rect: CGRect) -> Path {
        let start = axis == .horizontal ? CGPoint(x: rect.minX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.minY)
        let end = axis == .horizontal ? CGPoint(x: rect.maxX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.maxY)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        func head(at tip: CGPoint, from base: CGPoint) {
            let angle = atan2(tip.y - base.y, tip.x - base.x)
            for turn in [0.8 * CGFloat.pi, -0.8 * CGFloat.pi] {
                path.move(to: tip)
                path.addLine(to: CGPoint(x: tip.x + 6 * cos(angle + turn), y: tip.y + 6 * sin(angle + turn)))
            }
        }
        if startHead { head(at: start, from: end) }
        if endHead { head(at: end, from: start) }
        return path
    }
}
