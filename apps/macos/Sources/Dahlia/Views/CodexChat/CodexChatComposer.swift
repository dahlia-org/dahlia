import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CodexChatComposer: View {
    @Bindable var session: CodexChatSessionModel
    let configurationPresentation: Binding<Bool>?
    var mcpSettingsDefaults: UserDefaults = .standard
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var mcpSettings = AgentMCPSettings()
    @State private var showsMeetingPicker = false
    @State private var meetingQuery = ""
    @State private var highlightedMeetingID: UUID?
    @State private var suggestions: [CodexChatMeetingReference] = []
    @State private var consumesTrailingMentionOnSelection = false
    @State private var isImageImporterPresented = false
    @State private var isImageDropTargeted = false
    @State private var showsAddPanel = false
    @State private var showsSlashCommands = false
    @State private var slashCommands: [CodexChatSlashCommand] = []
    @State private var highlightedCommandID: String?
    @State private var isLoadingCommands = false
    @State private var commandError: String?
    @State private var slashWindowBounds: CGRect = .zero
    @State private var composerSize: CGSize = .zero
    @State private var slashPanelSize: CGSize = .zero
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CodexChatDesign.floatingPanelSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                if !session.attachedImages.isEmpty {
                    CodexChatAttachmentStrip(
                        attachments: session.attachedImages,
                        onRemove: session.removeAttachedImage
                    )
                }

                if !session.selectedMeetingReferenceIDs.isEmpty {
                    CodexChatMeetingReferenceBar(
                        referenceIDs: session.selectedMeetingReferenceIDs,
                        referencesByID: session.meetingReferencesByID,
                        onRemove: session.removeMeetingReference
                    )
                }

                if let validationMessage = session.attachmentValidationMessage {
                    CodexChatAttachmentValidationView(message: validationMessage)
                }

                CodexChatComposerInputRow(
                    session: session,
                    configurationPresentation: configurationPresentation,
                    addPanel: showsAddPanel ? { bounds in
                        CodexChatAddPanel(
                            windowBounds: bounds,
                            showsMeetingPicker: showsMeetingPicker,
                            showsConnectors: session.backendThreadID == nil && session.messages.isEmpty,
                            meetingReferences: suggestions,
                            highlightedMeetingID: highlightedMeetingID,
                            mcpSettings: mcpSettings,
                            onAttachImages: showImageImporter,
                            onAddMeetingReference: showMeetingPicker,
                            onSelectMeeting: selectMeeting,
                            onOpenMCPSettings: openMCPSettings
                        )
                    } : nil,
                    onDismissAddPanel: dismissAddPanel,
                    isComposerFocused: $isComposerFocused,
                    onToggleAddPanel: toggleAddPanel,
                    onPasteImages: pasteImages,
                    onSubmit: handleSubmit,
                    onMoveCommand: handleMoveCommand,
                    onExitCommand: dismissPanels,
                    onHover: updateTextInputCursor,
                    onComplete: completeSlashCommand,
                    handlesVerticalKeys: showsSlashCommands
                )
            }
            .padding(CodexChatDesign.composerContentPadding)
            .background {
                CodexChatComposerBackground(isDropTargeted: isImageDropTargeted)
            }
            .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
        }
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.bounds(of: .named(CodexChatAddPanelLayout.coordinateSpaceName))
                ?? geometry.bounds(of: .named(DahliaWindowHeaderHelpLayout.windowCoordinateSpaceName)) ?? .zero
        } action: { slashWindowBounds = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { composerSize = $0 }
        .overlay(alignment: .topLeading) {
            if showsSlashCommands {
                CodexChatSlashCommandPicker(
                    commands: commandSuggestions,
                    highlightedID: highlightedCommandID,
                    isLoading: isLoadingCommands,
                    errorMessage: commandError,
                    maximumHeight: CodexChatSlashCommandLayout.maximumHeight(in: slashWindowBounds, composerHeight: composerSize.height),
                    onSelect: selectCommand
                )
                .frame(width: CodexChatSlashCommandLayout.width(in: slashWindowBounds))
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { slashPanelSize = $0 }
                .codexChatDismissOnOutsideClick { showsSlashCommands = false }
                .offset(CodexChatSlashCommandLayout.offset(panelSize: slashPanelSize, in: slashWindowBounds, composerHeight: composerSize.height))
                .opacity(slashPanelSize == .zero ? 0 : 1)
            }
        }
        .zIndex(showsAddPanel || showsSlashCommands ? 1 : 0)
        .background {
            if !showsAddPanel, !showsSlashCommands {
                CodexChatOutsideClickMonitor(onOutsideClick: dismissComposerFocus)
            }
        }
        .onChange(of: session.id) { dismissPanels() }
        .onAppear { handleDraftChange("", session.draft) }
        .task(id: showsSlashCommands) {
            guard showsSlashCommands else { return }
            isLoadingCommands = true
            commandError = nil
            do {
                let commands = try await session.slashCommands()
                try Task.checkCancellation()
                slashCommands = commands
                highlightedCommandID = commandSuggestions.first?.id
                isLoadingCommands = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                slashCommands = []
                commandError = L10n.chatCommandsLoadFailed
                isLoadingCommands = false
            }
        }
        .onChange(of: session.draft, handleDraftChange)
        .onChange(of: session.availableMeetingReferences) {
            refreshSuggestionsIfPresented()
        }
        .onChange(of: session.selectedMeetingReferenceIDs) {
            refreshSuggestionsIfPresented()
        }
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: handleImageImport
        )
        .dropDestination(for: CodexChatTransferImage.self) { images, _ in
            addTransferImages(images)
        }
        .onDropSessionUpdated(updateDropTarget)
        .pasteDestination(for: CodexChatTransferImage.self, action: addTransferImages)
    }

    /// 追加パネルの表示中は、参照挿入後も入力を続けられるようにコンポーザーのフォーカスを保持する。
    static func dismissesComposerFocus(showsAddPanel: Bool) -> Bool {
        !showsAddPanel
    }

    private func dismissComposerFocus() {
        guard Self.dismissesComposerFocus(showsAddPanel: showsAddPanel) else { return }
        isComposerFocused = false
    }

    private func showImageImporter() {
        dismissAddPanel()
        isImageImporterPresented = true
    }

    private func toggleAddPanel() {
        showsSlashCommands = false
        guard !showsAddPanel else {
            dismissAddPanel()
            return
        }
        mcpSettings = AgentMCPSettings.load(for: session.runtimeProvider, defaults: mcpSettingsDefaults)
        meetingQuery = ""
        highlightedMeetingID = nil
        consumesTrailingMentionOnSelection = false
        showsMeetingPicker = false
        showsAddPanel = true
    }

    private func openMCPSettings() {
        dismissAddPanel()
        navigation.openAgentSettings(tab: .mcps)
    }

    private func handleImageImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            Task { await session.addImageURLs(urls) }
        case let .failure(error):
            let cocoaError = error as NSError
            guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError else { return }
            session.reportImageAttachmentFailure()
        }
    }

    private func addTransferImages(_ images: [CodexChatTransferImage]) {
        Task { await session.addImageData(images.map(\.data)) }
    }

    private func pasteImages() -> Bool {
        let imageData = CodexChatPasteboardImageReader.imageData()
        guard !imageData.isEmpty else { return false }
        Task { await session.addImageData(imageData) }
        return true
    }

    private func updateDropTarget(_ dropSession: DropSession) {
        switch dropSession.phase {
        case .entering, .active:
            isImageDropTargeted = true
        case .exiting, .ended, .dataTransferCompleted:
            isImageDropTargeted = false
        @unknown default:
            isImageDropTargeted = false
        }
    }

    private func handleSubmit() {
        if completeSlashCommand() { return }
        if showsSlashCommands, isLoadingCommands { return }
        if showsMeetingPicker,
           let highlightedMeetingID,
           let reference = suggestions.first(where: { $0.id == highlightedMeetingID }) {
            selectMeeting(reference)
            return
        }
        guard NSApp.currentEvent?.modifierFlags.contains(.shift) == true else {
            session.sendDraft()
            return
        }

        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            session.draft.append("\n")
            return
        }

        textView.insertNewlineIgnoringFieldEditor(nil)
    }

    private func handleDraftChange(_: String, _ newValue: String) {
        if CodexChatSlashCommand.query(in: newValue) != nil {
            dismissAddPanel()
            if !showsSlashCommands { isLoadingCommands = true }
            showsSlashCommands = true
            highlightedCommandID = commandSuggestions.first?.id
            return
        }
        showsSlashCommands = false
        guard let query = CodexChatMeetingReference.trailingMentionQuery(in: newValue) else {
            if showsMeetingPicker {
                dismissAddPanel()
            }
            return
        }
        meetingQuery = query
        consumesTrailingMentionOnSelection = true
        showsMeetingPicker = true
        showsAddPanel = true
        refreshSuggestions()
    }

    private func showMeetingPicker() {
        meetingQuery = ""
        consumesTrailingMentionOnSelection = false
        showsMeetingPicker = true
        showsAddPanel = true
        refreshSuggestions()
    }

    private func dismissAddPanel() {
        showsAddPanel = false
        showsMeetingPicker = false
        meetingQuery = ""
        highlightedMeetingID = nil
        consumesTrailingMentionOnSelection = false
    }

    private func dismissPanels() {
        dismissAddPanel()
        showsSlashCommands = false
    }

    private var commandSuggestions: [CodexChatSlashCommand] {
        guard let query = CodexChatSlashCommand.query(in: session.draft) else { return [] }
        return CodexChatSlashCommand.suggestions(from: slashCommands, query: query)
    }

    private func selectCommand(_ command: CodexChatSlashCommand) {
        session.draft = "/" + command.name + " "
        showsSlashCommands = false
        isComposerFocused = true
    }

    private func completeSlashCommand() -> Bool {
        guard showsSlashCommands, !isLoadingCommands,
              let command = commandSuggestions.first(where: { $0.id == highlightedCommandID })
        else { return false }
        selectCommand(command)
        return true
    }

    private func selectMeeting(_ reference: CodexChatMeetingReference) {
        session.draft = CodexChatMeetingReference.draftAfterSelectingReference(
            session.draft,
            consumesTrailingMention: consumesTrailingMentionOnSelection
        )
        session.addMeetingReference(reference)
        dismissAddPanel()
    }

    private func refreshSuggestionsIfPresented() {
        guard showsMeetingPicker else { return }
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        suggestions = CodexChatMeetingReference.suggestions(
            from: session.availableMeetingReferences,
            excluding: session.selectedMeetingReferenceIDs,
            query: meetingQuery
        )
        updateHighlightedMeeting()
    }

    private func updateHighlightedMeeting() {
        guard !suggestions.contains(where: { $0.id == highlightedMeetingID }) else { return }
        highlightedMeetingID = suggestions.first?.id
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        if showsSlashCommands {
            let commands = commandSuggestions
            guard !commands.isEmpty, direction == .up || direction == .down else { return }
            let index = commands.firstIndex { $0.id == highlightedCommandID } ?? 0
            let offset = direction == .up ? -1 : 1
            highlightedCommandID = commands[(index + offset + commands.count) % commands.count].id
            return
        }
        guard showsMeetingPicker, !suggestions.isEmpty else { return }
        switch direction {
        case .up:
            highlightedMeetingID = CodexChatMeetingPickerSelection.moving(
                currentID: highlightedMeetingID,
                in: suggestions,
                by: -1
            )
        case .down:
            highlightedMeetingID = CodexChatMeetingPickerSelection.moving(
                currentID: highlightedMeetingID,
                in: suggestions,
                by: 1
            )
        default:
            return
        }
    }

    private func updateTextInputCursor(_ phase: HoverPhase) {
        switch phase {
        case .active:
            NSCursor.iBeam.set()
        case .ended:
            NSCursor.arrow.set()
        }
    }
}
