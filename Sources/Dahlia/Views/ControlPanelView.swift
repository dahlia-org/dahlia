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
    /// 前後送りの対象範囲。開いた画面の文脈をそのまま保つ。
    enum Scope {
        /// スクリーンショット一覧タブ。ミーティングの全スクリーンショットを撮影順にたどる。
        case allScreenshots
        /// 要約タブ。要約本文に埋め込まれた画像だけを出現順にたどる。
        case summary
    }

    let screenshot: MeetingScreenshotRecord
    let previewImage: CGImage?
    let requestedAt: ContinuousClock.Instant
    let scope: Scope
}

/// メインコントロールウィンドウ（議事録ビュー）。
struct ControlPanelView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator

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
                        recordingCoordinator: recordingCoordinator,
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

            if let batchTranscriptionState = viewModel.batchTranscriptionState {
                BatchTranscriptionStatusBanner(
                    state: batchTranscriptionState,
                    canAct: viewModel.canStartOrResumeBatchTranscription,
                    actionTitle: viewModel.batchTranscriptionActionTitle,
                    onAction: viewModel.presentAvailableBatchRetranscription,
                    onDiscard: viewModel.discardFailedBatchTranscription,
                    onKeepCurrentTranscript: viewModel.cancelFailedBatchRetranscription
                )
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
        .frame(minWidth: MainSidebarLayout.minimumDetailWidth, minHeight: 500)
        .frame(maxWidth: DahliaDesign.mainContentMaxWidth, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    canGoPrevious: canStepExpandedScreenshot(by: -1),
                    canGoNext: canStepExpandedScreenshot(by: 1),
                    onPrevious: { stepExpandedScreenshot(by: -1) },
                    onNext: { stepExpandedScreenshot(by: 1) },
                    onDismiss: dismissExpandedScreenshot
                )
                .transition(.opacity)
            }
        }
    }

    // MARK: - Tab Contents

    private func detailErrorBanner(message: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .dahliaFixedSymbol()
                .foregroundStyle(.orange)
            Text(message)
                .font(.body)
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(8)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: DahliaDesign.Feedback.cornerRadius)
        )
        .padding(.horizontal, DahliaDesign.detailHorizontalPadding)
        .padding(.vertical, 4)
    }

    private var summaryTabContent: some View {
        ZStack(alignment: .topTrailing) {
            SummaryTabContentView(
                screenshotStore: viewModel.screenshotStore,
                document: viewModel.currentSummaryDocument,
                meetingDescription: currentMeetingItem?.meetingDescription,
                hasSummary: viewModel.hasCurrentMeetingSummary,
                openScreenshot: openSummaryScreenshot,
                transcriptText: summaryTranscriptText
            )
            .padding(.trailing, 56)

            VStack(spacing: 8) {
                ShareSummaryFloatingButton(viewModel: viewModel)
                GenerateSummaryFloatingButton(
                    viewModel: viewModel,
                    sidebarViewModel: sidebarViewModel
                )
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
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
                            .foregroundStyle(DahliaDesign.optionalTextColor)
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
            open: { openScreenshot($0, previewImage: $1, scope: .allScreenshots) },
            download: viewModel.downloadScreenshot,
            delete: viewModel.deleteScreenshot,
            deleteSelected: deleteSelectedScreenshots
        )
    }

    private func openScreenshot(
        _ screenshot: MeetingScreenshotRecord,
        previewImage: CGImage?,
        scope: ExpandedScreenshotPresentation.Scope
    ) {
        let presentation = ExpandedScreenshotPresentation(
            screenshot: screenshot,
            previewImage: previewImage,
            requestedAt: .now,
            scope: scope
        )
        withAnimation(.easeOut(duration: 0.15)) {
            expandedScreenshot = presentation
        }
    }

    private func openSummaryScreenshot(_ screenshotID: UUID, previewImage: CGImage) {
        guard let screenshot = screenshotRecord(withID: screenshotID) else { return }
        openScreenshot(screenshot, previewImage: previewImage, scope: .summary)
    }

    private func screenshotRecord(withID id: UUID) -> MeetingScreenshotRecord? {
        viewModel.screenshotStore.records.first { $0.id == id }
    }

    /// 拡大表示中に削除や再生成が起きても追従できるよう、移動対象は都度現在の state から組み立てる。
    private func expandedScreenshotNavigationIDs(for scope: ExpandedScreenshotPresentation.Scope) -> [UUID] {
        switch scope {
        case .allScreenshots:
            viewModel.screenshotStore.records.map(\.id)
        case .summary:
            (viewModel.currentSummaryDocument?.orderedScreenshotIds ?? [])
                .filter { screenshotRecord(withID: $0) != nil }
        }
    }

    private func neighborExpandedScreenshot(by offset: Int) -> MeetingScreenshotRecord? {
        guard let presentation = expandedScreenshot else { return nil }
        guard let neighborID = ScreenshotOverlayNavigation.neighborID(
            in: expandedScreenshotNavigationIDs(for: presentation.scope),
            from: presentation.screenshot.id,
            offset: offset
        ) else { return nil }
        return screenshotRecord(withID: neighborID)
    }

    private func canStepExpandedScreenshot(by offset: Int) -> Bool {
        neighborExpandedScreenshot(by: offset) != nil
    }

    private func stepExpandedScreenshot(by offset: Int) {
        guard let presentation = expandedScreenshot,
              let neighbor = neighborExpandedScreenshot(by: offset) else { return }
        expandedScreenshot = ExpandedScreenshotPresentation(
            screenshot: neighbor,
            previewImage: nil,
            requestedAt: .now,
            scope: presentation.scope
        )
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

    private var meetingMetadataText: String {
        let activeRecordingStartedAt = viewModel.isListening
            && viewModel.recordingMeetingId == viewModel.currentMeetingId
            ? viewModel.store.recordingStartTime
            : nil
        let recordingStartedAt = currentMeetingItem?.recordingStartedAt
            ?? activeRecordingStartedAt
            ?? viewModel.draftMeeting?.linkedCalendarEvent?.startDate
            ?? viewModel.store.recordingStartTime
            ?? currentMeetingItem?.createdAt
            ?? Date.now
        var parts = [recordingStartedAt.formatted(date: .abbreviated, time: .shortened)]

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
