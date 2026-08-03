import DahliaRuntimeSupport
import SwiftUI

private enum NotesEditorLayout {
    static let editorPadding = EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
    /// `TextEditor` keeps a small internal inset on macOS, so the placeholder needs
    /// a matching offset instead of using the same outer padding.
    static let placeholderPadding = EdgeInsets(top: 10, leading: 9, bottom: 0, trailing: 0)
}

/// メイン領域のタブ種別。
enum DetailTab: String, CaseIterable, Identifiable {
    case summary
    case notes
    case screenshots
    case transcript
    case conversationAnalytics

    var id: String { rawValue }

    var label: String {
        switch self {
        case .summary: L10n.summary
        case .notes: L10n.notes
        case .screenshots: L10n.screenshots
        case .transcript: L10n.transcript
        case .conversationAnalytics: L10n.conversationAnalytics
        }
    }
}

private struct ExpandedScreenshotPresentation {
    let screenshot: MeetingScreenshotRecord
    let previewImage: CGImage?
    let requestedAt: ContinuousClock.Instant
}

/// ミーティング詳細のタイトル。クリックでインライン編集できる。
private struct MeetingNameHeader: View {
    let title: String
    @Binding var isEditing: Bool
    @Binding var editingName: String
    @FocusState.Binding var isFocused: Bool
    let onBeginEditing: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onEditorTap: () -> Void
    @State private var isHovered = false
    @FocusState private var isTitleButtonFocused: Bool

    private var displayName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.newMeeting : trimmed
    }

    var body: some View {
        Group {
            if isEditing {
                TextField(L10n.title, text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .focused($isFocused)
                    .onSubmit(onCommit)
                    .onExitCommand(perform: onCancel)
                    .onChange(of: isFocused) { _, focused in
                        if !focused, isEditing {
                            onCommit()
                        }
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            onEditorTap()
                        }
                    )
                    .task {
                        editingName = title
                        try? await Task.sleep(for: .milliseconds(50))
                        isFocused = true
                    }
            } else {
                Button(action: onBeginEditing) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .opacity(isHovered || isTitleButtonFocused ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($isTitleButtonFocused)
                .onHover { hovering in
                    isHovered = hovering
                }
                .help(L10n.rename)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: title) { _, newTitle in
            isEditing = false
            editingName = newTitle
        }
    }
}

private struct MeetingDetailHeader: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let title: String
    let metadataText: String
    let calendarEvent: CalendarEventDisplayInfo?
    @Binding var isEditing: Bool
    @Binding var editingName: String
    @FocusState.Binding var isFocused: Bool
    let onBeginEditing: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onEditorTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MeetingNameHeader(
                title: title,
                isEditing: $isEditing,
                editingName: $editingName,
                isFocused: $isFocused,
                onBeginEditing: onBeginEditing,
                onCommit: onCommit,
                onCancel: onCancel,
                onEditorTap: onEditorTap
            )

            metadataStack
        }
        .padding(.bottom, 2)
    }

    private var metadataStack: some View {
        MeetingMetadataBar(
            viewModel: viewModel,
            sidebarViewModel: sidebarViewModel,
            metadataText: metadataText,
            calendarEvent: calendarEvent
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// メインコントロールウィンドウ（議事録ビュー）。
struct ControlPanelView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    let allowsTranscriptReferencePopovers: Bool
    @ObservedObject private var appSettings = AppSettings.shared
    @State private var selectedTab: DetailTab = .summary
    @State private var expandedScreenshot: ExpandedScreenshotPresentation?
    @State private var screenshotMinimumWidth = ScreenshotGridSizing.defaultMinimumWidth
    @State private var isSelectingScreenshots = false
    @State private var selectedScreenshotIds: Set<UUID> = []
    @State private var isConfirmingScreenshotDeletion = false
    @State private var isEditingMeetingName = false
    @State private var editingMeetingName = ""
    @State private var pendingMeetingDeletion: MeetingDeletionRequest?
    @State private var didTapInsideMeetingNameEditor = false
    @State private var didTapInsideNotesField = false
    @FocusState private var isMeetingNameFieldFocused: Bool
    @FocusState private var isNotesFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                // 準備中プログレス
                if viewModel.isPreparingAnalyzer {
                    ProgressView(L10n.preparingSpeechRecognition)
                        .progressViewStyle(.linear)
                }

                if let meetingTitle = displayedMeetingTitle,
                   viewModel.hasDraftMeeting || viewModel.currentMeetingId != nil {
                    MeetingDetailHeader(
                        viewModel: viewModel,
                        sidebarViewModel: sidebarViewModel,
                        title: meetingTitle,
                        metadataText: meetingMetadataText,
                        calendarEvent: displayedCalendarEvent,
                        isEditing: $isEditingMeetingName,
                        editingName: $editingMeetingName,
                        isFocused: $isMeetingNameFieldFocused,
                        onBeginEditing: beginMeetingRename,
                        onCommit: commitMeetingRename,
                        onCancel: cancelMeetingRename,
                        onEditorTap: markMeetingNameEditorTap
                    )
                }

                MeetingDetailNavigationBar(
                    selection: $selectedTab,
                    viewModel: viewModel,
                    onRename: beginMeetingRename,
                    onDelete: requestCurrentMeetingDeletion
                )
            }
            .padding(.horizontal, DahliaDesign.detailHorizontalPadding)
            .padding(.top, DahliaDesign.detailTopPadding)

            Divider()
                .opacity(0.5)

            // タブコンテンツ
            Group {
                switch selectedTab {
                case .summary:
                    summaryTabContent
                case .notes:
                    notesTabContent
                case .screenshots:
                    screenshotsTabContent
                case .transcript:
                    TranscriptTabView(
                        store: viewModel.store,
                        allowsTextSelection: !viewModel.isListening,
                        showsTranslatedText: appSettings.isTranscriptTranslationEffectivelyEnabled,
                        retryInitialMeetingLoad: viewModel.retryInitialMeetingLoad
                    )
                case .conversationAnalytics:
                    ConversationAnalyticsDashboardView(
                        store: viewModel.conversationMetricsStore,
                        meetingId: viewModel.currentMeetingId,
                        isAnalysisPending: viewModel.isCurrentMeetingConversationAnalysisPending,
                        hasTranscript: viewModel.currentMeetingHasTranscriptSegments,
                        load: viewModel.loadCurrentMeetingConversationMetrics
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 280)
            .background {
                Rectangle().fill(tabContentBackgroundColor)
            }

            // エラー表示
            if let error = viewModel.errorMessage {
                detailErrorBanner(message: error, tint: .red)
            }

            if let summaryError = viewModel.summaryError {
                detailErrorBanner(message: summaryError, tint: .red)
            }

            if let googleDocsExportError = viewModel.googleDocsExportError {
                detailErrorBanner(message: googleDocsExportError, tint: .orange)
            }
        }
        .frame(minWidth: 500, minHeight: 500)
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissFocusedInputs()
            }
        )
        .onChange(of: viewModel.requestShowSummaryTab) {
            updateSummaryTabSelection()
        }
        .onChange(of: isSelectingScreenshots) { _, isSelecting in
            if !isSelecting {
                selectedScreenshotIds.removeAll()
            }
        }
        .onChange(of: displayedMeetingIdentity) { oldIdentity, newIdentity in
            if oldIdentity == nil, newIdentity != nil {
                selectedTab = initialTabSelection
            }
            viewModel.requestShowSummaryTab = false
            cancelMeetingRename()
            isSelectingScreenshots = false
            selectedScreenshotIds.removeAll()
        }
        .onChange(of: appSettings.isConversationAnalyticsBetaEnabled) { _, isEnabled in
            if !isEnabled, selectedTab == .conversationAnalytics {
                selectedTab = .transcript
            }
        }
        .confirmationDialog(
            L10n.deleteCount(selectedScreenshotIds.count),
            isPresented: $isConfirmingScreenshotDeletion,
            titleVisibility: .visible
        ) {
            Button(L10n.delete, role: .destructive, action: confirmDeleteSelectedScreenshots)
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.deleteSelectedScreenshotsConfirmation)
        }
        .meetingDeletionConfirmation(request: $pendingMeetingDeletion) { meetingIds in
            sidebarViewModel.deleteMeetings(ids: meetingIds)
            if let meetingId = viewModel.currentMeetingId,
               meetingIds.contains(meetingId) {
                viewModel.clearCurrentMeeting()
            }
        }
        .overlay {
            if let presentation = expandedScreenshot {
                ScreenshotOverlayView(
                    screenshot: presentation.screenshot,
                    previewImage: presentation.previewImage,
                    requestedAt: presentation.requestedAt,
                    onDismiss: dismissExpandedScreenshot
                )
                .transition(.opacity)
            }
        }
        .toolbar {
            detailToolbar
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            ShareSummaryToolbarButton(viewModel: viewModel)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            GenerateSummaryToolbarButton(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel
            )
        }

        if showsToolbarRecordButton {
            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                RecordToolbarButton(
                    viewModel: viewModel,
                    sidebarViewModel: sidebarViewModel,
                    recordingCoordinator: recordingCoordinator
                )
            }
        }
    }

    // MARK: - Tab Contents

    private func detailErrorBanner(message: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, DahliaDesign.detailHorizontalPadding)
        .padding(.vertical, 4)
    }

    private var summaryTabContent: some View {
        SummaryTabContentView(
            screenshotStore: viewModel.screenshotStore,
            document: viewModel.currentSummaryDocument,
            hasSummary: viewModel.hasCurrentMeetingSummary,
            allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers,
            openScreenshot: openSummaryScreenshot,
            transcriptText: summaryTranscriptText
        )
    }

    private var notesTabContent: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.noteText)
                        .font(.body)
                        .focused($isNotesFieldFocused)
                        .scrollContentBackground(.hidden)
                        .frame(height: notesEditorHeight(for: proxy.size.height))
                        .padding(NotesEditorLayout.editorPadding)
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                didTapInsideNotesField = true
                            }
                        )

                    if viewModel.noteText.isEmpty {
                        Text(L10n.notesPlaceholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(NotesEditorLayout.placeholderPadding)
                            .allowsHitTesting(false)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(DahliaDesign.tabContentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func notesEditorHeight(for availableHeight: CGFloat) -> CGFloat {
        let reservedBottomSpace: CGFloat = 96
        let minimumHeight: CGFloat = 140
        let preferredHeight = availableHeight * 0.85
        let maximumHeight = max(minimumHeight, availableHeight - reservedBottomSpace)
        return min(max(minimumHeight, preferredHeight), maximumHeight)
    }

    private var screenshotsTabContent: some View {
        ScreenshotTabContentView(
            screenshotStore: viewModel.screenshotStore,
            meetingID: viewModel.currentMeetingId,
            recordingSessions: viewModel.store.recordingSessions,
            fallbackTimeBase: screenshotTimeBase,
            minimumItemWidth: $screenshotMinimumWidth,
            isSelecting: $isSelectingScreenshots,
            selectedScreenshotIDs: $selectedScreenshotIds,
            referencedScreenshotIDs: referencedScreenshotIds,
            isDeletionDisabled: viewModel.isSummaryGenerating || viewModel.isDeletingScreenshots,
            open: openScreenshot,
            download: viewModel.downloadScreenshot,
            delete: viewModel.deleteScreenshot,
            deleteSelected: deleteSelectedScreenshots
        )
    }

    private func openScreenshot(_ screenshot: MeetingScreenshotRecord, previewImage: CGImage?) {
        let presentation = ExpandedScreenshotPresentation(
            screenshot: screenshot,
            previewImage: previewImage,
            requestedAt: .now
        )
        withAnimation(.easeOut(duration: 0.15)) {
            expandedScreenshot = presentation
        }
    }

    private func openSummaryScreenshot(_ screenshotID: UUID, previewImage: CGImage) {
        guard let screenshot = screenshotRecord(withID: screenshotID) else { return }
        openScreenshot(screenshot, previewImage: previewImage)
    }

    private func screenshotRecord(withID id: UUID) -> MeetingScreenshotRecord? {
        viewModel.screenshotStore.records.first { $0.id == id }
    }

    private func dismissExpandedScreenshot() {
        guard expandedScreenshot != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            expandedScreenshot = nil
        }
    }

    private func deleteSelectedScreenshots() {
        isConfirmingScreenshotDeletion = true
    }

    private func confirmDeleteSelectedScreenshots() {
        viewModel.deleteScreenshots(ids: selectedScreenshotIds)
        selectedScreenshotIds.removeAll()
        isSelectingScreenshots = false
    }

    // MARK: - Computed

    private var currentMeetingItem: MeetingDetailItem? {
        guard let meetingId = viewModel.currentMeetingId else { return nil }
        guard sidebarViewModel.selectedMeetingDetail?.meetingId == meetingId else { return nil }
        return sidebarViewModel.selectedMeetingDetail
    }

    private var displayedCalendarEvent: CalendarEventDisplayInfo? {
        currentMeetingItem?.calendarEvent
            ?? viewModel.draftMeeting?.linkedCalendarEvent.map { CalendarEventDisplayInfo(event: $0) }
    }

    private var screenshotTimeBase: Date {
        viewModel.store.timeBase
    }

    private var referencedScreenshotIds: Set<UUID> {
        viewModel.currentSummaryDocument?.referencedScreenshotIds ?? []
    }

    private func summaryTranscriptText(for reference: TranscriptReference) -> String? {
        let time = reference.time.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !time.isEmpty else { return nil }

        let timeBase = viewModel.store.timeBase
        let recordingSessions = viewModel.store.recordingSessions
        return viewModel.store.segments.first { segment in
            Formatters.elapsedHHmmss(
                at: segment.startTime,
                sessionId: segment.sessionId,
                sessions: recordingSessions,
                fallbackTimeBase: timeBase
            ) == time
        }?.displayText.nilIfBlank
    }

    private var displayedMeetingTitle: String? {
        if let currentMeetingItem {
            return currentMeetingItem.meetingName
        }
        if viewModel.currentMeetingId != nil {
            return ""
        }
        if viewModel.hasDraftMeeting {
            return viewModel.draftMeeting?.title ?? ""
        }
        return nil
    }

    private var displayedMeetingIdentity: String? {
        if let currentMeetingItem {
            return currentMeetingItem.meetingId.uuidString
        }
        if let currentMeetingId = viewModel.currentMeetingId {
            return currentMeetingId.uuidString
        }
        if viewModel.hasDraftMeeting {
            return "draft"
        }
        return nil
    }

    private var tabContentBackgroundColor: Color {
        selectedTab == .notes ? Color(nsColor: .textBackgroundColor) : Color(nsColor: .windowBackgroundColor)
    }

    private var showsToolbarRecordButton: Bool {
        RecordingCommandState.showsDetailCommand(
            isListening: viewModel.isListening,
            recordingMeetingID: viewModel.recordingMeetingId,
            currentMeetingID: viewModel.currentMeetingId
        )
    }

    private var meetingMetadataText: String {
        let createdAt = currentMeetingItem?.createdAt ?? viewModel.store.recordingStartTime ?? Date()
        var parts = [createdAt.formatted(date: .abbreviated, time: .shortened)]

        if let duration = currentMeetingItem?.duration {
            parts.append(formatDuration(duration))
        } else if viewModel.isListening {
            parts.append(L10n.recordingNow)
        }

        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func beginMeetingRename() {
        editingMeetingName = displayedMeetingTitle ?? ""
        isEditingMeetingName = true
        didTapInsideMeetingNameEditor = false
    }

    private func cancelMeetingRename() {
        editingMeetingName = displayedMeetingTitle ?? ""
        isEditingMeetingName = false
        isMeetingNameFieldFocused = false
        didTapInsideMeetingNameEditor = false
    }

    private func commitMeetingRename() {
        guard isEditingMeetingName else { return }
        let trimmed = editingMeetingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let currentMeetingItem {
            sidebarViewModel.renameMeeting(id: currentMeetingItem.meetingId, newName: trimmed)
        } else if viewModel.hasDraftMeeting {
            viewModel.updateDraftMeetingTitle(trimmed)
            if let meetingId = viewModel.materializeDraftMeeting(
                customerIntelligenceIngestion: .afterMeetingPersistence
            ) {
                sidebarViewModel.selectMeeting(meetingId)
            }
        }
        isEditingMeetingName = false
        isMeetingNameFieldFocused = false
        didTapInsideMeetingNameEditor = false
    }

    private func requestCurrentMeetingDeletion() {
        guard let meetingId = viewModel.currentMeetingId else { return }
        pendingMeetingDeletion = MeetingDeletionRequest(
            meetingIds: [meetingId],
            meetingName: displayedMeetingTitle?.nilIfBlank
        )
    }

    private func markMeetingNameEditorTap() {
        didTapInsideMeetingNameEditor = true
    }

    private func dismissFocusedInputs() {
        if didTapInsideMeetingNameEditor {
            didTapInsideMeetingNameEditor = false
        } else if isEditingMeetingName {
            isMeetingNameFieldFocused = false
        }

        if didTapInsideNotesField {
            didTapInsideNotesField = false
        } else if isNotesFieldFocused {
            isNotesFieldFocused = false
        }
    }

    private func updateSummaryTabSelection() {
        if viewModel.requestShowSummaryTab {
            selectedTab = .summary
            viewModel.requestShowSummaryTab = false
        }
    }

    private var initialTabSelection: DetailTab {
        .summary
    }

}
