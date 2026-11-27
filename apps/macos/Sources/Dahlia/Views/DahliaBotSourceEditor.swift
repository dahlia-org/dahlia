import SwiftUI

/// Adds or changes one event source, as a card over the window. It asks only where to read from and what to read; the
/// rest starts from what most people want, and the name and senders wait under Advanced.
struct DahliaBotSourceEditor: View {
    @Bindable var model: DahliaBotPanelModel
    @State private var isConfirmingDelete = false

    var body: some View {
        let draft = Binding(get: { model.draft ?? .init() }, set: { model.draft = $0 })
        let isNew = model.draft?.id == nil
        ZStack {
            Button(action: cancel) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                ProjectEditorSheetHeader(
                    title: isNew ? L10n.agentAlwaysOnAddSource : L10n.agentAlwaysOnEditSource,
                    isDisabled: model.isBusy,
                    onClose: cancel
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.agentAlwaysOnChooseSource).font(.dahliaSectionHeader).foregroundStyle(.secondary)
                    if isNew {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                            Button { model.chooseCalendar() } label: {
                                Label(L10n.agentCalendarSource, systemImage: "calendar").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.dahlia(draft.wrappedValue.kind == "calendar" ? .primary : .secondary))
                            .accessibilityAddTraits(draft.wrappedValue.kind == "calendar" ? .isSelected : [])
                            ForEach(model.serverGroups, id: \.self) { group in
                                let selected = draft.wrappedValue.kind == "mcp" && group.contains(draft.wrappedValue.server)
                                Button { if !selected, let first = group.first { model.choose(server: first) } } label: {
                                    groupLabel(group[0]).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.dahlia(selected ? .primary : .secondary))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                    } else if draft.wrappedValue.kind == "calendar" {
                        Label(L10n.agentCalendarSource, systemImage: "calendar")
                    } else {
                        // Its events belong to this server, so an existing source keeps it.
                        serverLabel(draft.wrappedValue.server)
                    }
                }
                Form {
                    if draft.wrappedValue.kind == "calendar" {
                        calendarSections(draft)
                    } else {
                        Section {
                            if let sourceID = draft.wrappedValue.id {
                                LabeledContent(L10n.agentAlwaysOnServer, value: model.sourceChoiceName(sourceID))
                            } else if let group = model.serverGroups.first(where: { $0.contains(draft.wrappedValue.server) }) {
                                Picker(
                                    L10n.agentAlwaysOnServer,
                                    selection: Binding(get: { draft.wrappedValue.server }, set: { model.choose(server: $0) })
                                ) {
                                    ForEach(group, id: \.self) { Text(model.choiceName($0)).font(.dahliaBody).tag($0) }
                                }
                            }
                            serviceRows(draft)
                            Picker(L10n.agentAlwaysOnInterval, selection: draft.intervalMinutes) {
                                ForEach(Set(DahliaBotPanelModel.intervals + [draft.wrappedValue.intervalMinutes]).sorted(), id: \.self) {
                                    Text(L10n.agentAlwaysOnIntervalMinutes($0)).font(.dahliaBody).tag($0)
                                }
                            }
                        }
                    }
                    Section {
                        DisclosureGroup(L10n.agentAlwaysOnAdvanced) {
                            TextField(
                                L10n.name,
                                text: draft.name,
                                prompt: Text(draft.wrappedValue.kind == "calendar" ? DahliaBotPanelModel.calendarName : model
                                    .displayName(draft.wrappedValue.server))
                            )
                            if draft.wrappedValue.kind != "calendar", draft.wrappedValue.service.isEmpty {
                                TextField(
                                    L10n.agentAlwaysOnAllowedSenders,
                                    text: draft.allowedSenders,
                                    prompt: Text(L10n.agentAlwaysOnAllowedSendersPlaceholder)
                                )
                            }
                        }
                        // The same text intake sends, so a choice's effect can be checked before saving. The calendar
                        // runs no intake; the app writes its signals.
                        if draft.wrappedValue.kind != "calendar" {
                            DisclosureGroup(L10n.agentSourcePromptPreview) {
                                Text(model.draftPrompt)
                                    .font(.dahliaSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .disclosureGroupStyle(MCPDisclosureGroupStyle())
                }
                .formStyle(.grouped)
                .toggleStyle(.dahliaSwitch)
                .font(.dahliaBody)
                .disabled(model.isBusy)

                if let error = model.error {
                    SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
                }
                HStack(spacing: 12) {
                    if !isNew {
                        Button(role: .destructive) { isConfirmingDelete = true } label: {
                            Text(L10n.delete).padding(.vertical, 3)
                        }
                        .buttonStyle(.dahlia(.destructive))
                        .disabled(model.isBusy)
                    }
                    Spacer()
                    Button(role: .cancel, action: cancel) { Text(L10n.cancel).frame(minWidth: 64).padding(.vertical, 3) }
                        .buttonStyle(.dahlia(.secondary))
                        .keyboardShortcut(.cancelAction)
                    Button { Task { await model.saveDraft() } } label: {
                        Text(isNew ? L10n.add : L10n.save).frame(minWidth: 64).padding(.vertical, 3)
                    }
                    .buttonStyle(.dahlia(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        model.isBusy || (draft.wrappedValue.kind == "mcp" && draft.wrappedValue.server.isEmpty)
                            || model.draftSource(draft.wrappedValue).lacksSlackChannels
                    )
                }
            }
            .padding(24)
            .frame(width: 540, height: 600)
            .dahliaModalSurface()
        }
        .transition(.identity)
        .confirmationDialog(L10n.agentAlwaysOnDeleteSource, isPresented: $isConfirmingDelete) {
            Button(L10n.delete, role: .destructive) { Task { await model.deleteDraft() } }
        } message: {
            Text(L10n.agentAlwaysOnDeleteSourceMessage)
        }
    }

    @ViewBuilder
    private func serviceRows(_ draft: Binding<DahliaBotPanelModel.Draft>) -> some View {
        switch draft.wrappedValue.service {
        case "mail":
            SettingsInfoToggle(title: L10n.agentMailAddressedOnly, help: L10n.agentMailAddressedOnlyHelp, isOn: draft.addressedOnly)
            LabeledContent {
                TextField(L10n.agentAlwaysOnAllowedSenders, text: draft.allowedSenders, prompt: Text(L10n.agentAlwaysOnAllowedSendersPlaceholder))
                    .labelsHidden()
            } label: {
                infoLabel(L10n.agentAlwaysOnAllowedSenders, help: L10n.agentMailSendersHelp)
            }
            TextField(L10n.agentMailAllowedDomains, text: draft.allowedDomains, prompt: Text(L10n.agentMailAllowedDomainsPlaceholder))
            notesField(draft)
        case "slack":
            Picker(L10n.agentSlackScope, selection: draft.slackScope) {
                Text(L10n.agentSlackScopeMentions).font(.dahliaBody).tag(AgentSourceOptions.SlackScope.mentions)
                Text(L10n.agentSlackScopeJoined).font(.dahliaBody).tag(AgentSourceOptions.SlackScope.joined)
                Text(L10n.agentSlackScopeAll).font(.dahliaBody).tag(AgentSourceOptions.SlackScope.all)
            }
            LabeledContent {
                TextField(L10n.agentSlackIncludeChannels, text: draft.includeChannels, prompt: Text(L10n.agentSlackChannelsPlaceholder))
                    .labelsHidden()
            } label: {
                infoLabel(L10n.agentSlackIncludeChannels, help: L10n.agentSlackChannelsHelp)
            }
            TextField(L10n.agentSlackExcludeChannels, text: draft.excludeChannels, prompt: Text(L10n.agentSlackChannelsPlaceholder))
            notesField(draft)
            if model.draftSource(draft.wrappedValue).lacksSlackChannels {
                Text(L10n.agentSlackAllNeedsChannels).font(.dahliaSecondary).foregroundStyle(.red)
            }
        default:
            LabeledContent {
                TextField(
                    L10n.agentAlwaysOnInstructions,
                    text: draft.instructions,
                    prompt: Text(L10n.agentAlwaysOnInstructionsPlaceholder),
                    axis: .vertical
                )
                .lineLimit(2 ... 5)
                .labelsHidden()
            } label: {
                infoLabel(L10n.agentAlwaysOnInstructions, help: L10n.agentAlwaysOnInstructionsHelp)
            }
        }
    }

    private func notesField(_ draft: Binding<DahliaBotPanelModel.Draft>) -> some View {
        TextField(L10n.agentAlwaysOnNotes, text: draft.instructions, prompt: Text(L10n.agentAlwaysOnNotesPlaceholder), axis: .vertical)
            .lineLimit(1 ... 4)
    }

    /// One section per notice, so each one's toggle heads its own settings; the filter applies to all of them.
    @ViewBuilder
    private func calendarSections(_ draft: Binding<DahliaBotPanelModel.Draft>) -> some View {
        Section {
            Toggle(L10n.agentCalendarDaily, isOn: draft.dailyEnabled)
            if draft.wrappedValue.dailyEnabled {
                DatePicker(L10n.agentCalendarDailyTime, selection: draft.dailyTime, displayedComponents: .hourAndMinute)
            }
        }
        Section {
            Toggle(L10n.agentCalendarWeekly, isOn: draft.weeklyEnabled)
            if draft.wrappedValue.weeklyEnabled {
                let calendar = Calendar.current
                Picker(L10n.agentCalendarWeekday, selection: draft.weekday) {
                    // In the locale's week order; the tag is `Calendar`'s weekday, 1 for Sunday.
                    ForEach((0 ..< 7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }, id: \.self) {
                        Text(calendar.weekdaySymbols[$0 - 1]).font(.dahliaBody).tag($0)
                    }
                }
                DatePicker(L10n.agentCalendarDailyTime, selection: draft.weeklyTime, displayedComponents: .hourAndMinute)
            }
        }
        Section {
            SettingsInfoToggle(title: L10n.agentCalendarBeforeMeeting, help: L10n.agentCalendarScheduleHelp, isOn: draft.leadEnabled)
            if draft.wrappedValue.leadEnabled {
                TextField(L10n.agentCalendarLeadHours, value: draft.leadHours, format: .number)
            }
        }
        Section {
            SettingsInfoToggle(title: L10n.agentCalendarAcceptedOnly, help: L10n.agentCalendarAcceptedOnlyHelp, isOn: draft.acceptedOnly)
        }
    }

    private func infoLabel(_ title: String, help: String) -> some View {
        HStack {
            Text(title)
            SettingsInfoButton(help: help)
        }
    }

    private func groupLabel(_ server: String) -> some View {
        let group = model.group(server)
        let image = group == "mail" ? Image(systemName: "envelope") : AgentMCPServiceLogo
            .image(for: group == "slack" ? "slack" : model.services[server] ?? server)
        return HStack(spacing: 8) {
            image.resizable().scaledToFit().frame(width: 20, height: 20).accessibilityHidden(true)
            Text(model.groupDisplayName(server)).lineLimit(1)
        }
    }

    private func serverLabel(_ server: String) -> some View {
        HStack(spacing: 8) {
            AgentMCPServiceLogo.image(for: model.services[server] ?? server)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(model.displayName(server)).lineLimit(1)
        }
    }

    private func cancel() {
        guard !model.isBusy else { return }
        model.draft = nil
        model.error = nil
    }
}
