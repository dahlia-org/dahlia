import SwiftUI

private enum NotesEditorLayout {
    static let editorPadding = EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
    /// `TextEditor` keeps a small internal inset on macOS, so the placeholder needs
    /// a matching offset instead of using the same outer padding.
    static let placeholderPadding = EdgeInsets(top: 10, leading: 9, bottom: 0, trailing: 0)
}

/// メイン領域のタブ種別。
enum DetailTab: String, CaseIterable, Identifiable {
    case notes
    case screenshots
    case transcript
    case summary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .summary: L10n.summary
        case .notes: L10n.notes
        case .screenshots: L10n.screenshots
        case .transcript: L10n.transcript
        }
    }
}

/// スクリーンショット拡大表示オーバーレイ。
private struct ScreenshotOverlayView: View {
    /// Retina の全画面キャプチャを元解像度でレイヤー化すると、RenderBox の
    /// surface allocation が枯渇し得る。画面表示には十分なサイズへ制限する。
    private static let maximumDisplayPixelSize = 2400

    let screenshot: MeetingScreenshotRecord
    let onDismiss: () -> Void
    @StateObject private var imageLoader = ScreenshotImageLoadModel()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel(L10n.close)

            if case let .loaded(image) = imageLoader.state {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(24)
            } else if case .failed = imageLoader.state {
                Text(L10n.summaryImageUnavailable)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }

            Button(L10n.close, systemImage: "xmark.circle.fill", action: onDismiss)
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(.black)
                .padding(8)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .padding(16)
                .buttonStyle(.plain)
                .pointerStyle(.link)
        }
        .task(id: screenshot.id) {
            await imageLoader.load(
                screenshotID: screenshot.id,
                data: screenshot.imageData,
                maxPixelSize: Self.maximumDisplayPixelSize
            )
        }
    }
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
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

private struct MeetingActionsMenu: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let onRename: () -> Void

    private var canOpenSummary: Bool {
        viewModel.lastSummaryURL != nil || viewModel.currentSummaryGoogleFileURL != nil
    }

    var body: some View {
        Menu {
            Button(L10n.rename, systemImage: "pencil", action: onRename)

            if canOpenSummary {
                SummaryOpenMenu(viewModel: viewModel)
            }

            if viewModel.canRetranscribeBatchAudio {
                Button(
                    L10n.retranscribe,
                    systemImage: "arrow.clockwise",
                    action: viewModel.presentBatchRetranscriptionConfirmation
                )
            }

            Divider()

            Button(role: .destructive) {
                guard let meetingId = viewModel.currentMeetingId else { return }
                sidebarViewModel.deleteMeeting(id: meetingId)
                viewModel.clearCurrentMeeting()
            } label: {
                Label(L10n.delete, systemImage: "trash")
            }
            .disabled(viewModel.currentMeetingId == nil)
        } label: {
            Label(L10n.actions, systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
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
        VStack(alignment: .leading, spacing: 12) {
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

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    metadataStack
                    Spacer(minLength: 12)
                    controls
                }

                VStack(alignment: .leading, spacing: 12) {
                    metadataStack
                    controls
                }
            }
        }
        .padding(.bottom, 2)
    }

    private var metadataStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8, rowSpacing: 8) {
                if let calendarEvent {
                    CalendarEventMetadataButton(
                        text: metadataText,
                        event: calendarEvent
                    )
                } else {
                    MeetingMetadataPill(systemImage: "calendar", text: metadataText)
                }

                MeetingProjectPicker(
                    viewModel: viewModel,
                    sidebarViewModel: sidebarViewModel,
                    style: .regular
                )
            }

            MeetingMetadataBar(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        MeetingActionsMenu(
            viewModel: viewModel,
            sidebarViewModel: sidebarViewModel,
            onRename: onBeginEditing
        )
        .controlSize(.regular)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MeetingMetadataPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

/// メインコントロールウィンドウ（議事録ビュー）。
struct ControlPanelView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    @ObservedObject private var appSettings = AppSettings.shared
    @State private var selectedTab: DetailTab = .notes
    @State private var expandedScreenshot: MeetingScreenshotRecord?
    @State private var screenshotMinimumWidth = ScreenshotGridSizing.defaultMinimumWidth
    @State private var isSelectingScreenshots = false
    @State private var selectedScreenshotIds: Set<UUID> = []
    @State private var isConfirmingScreenshotDeletion = false
    @State private var isEditingMeetingName = false
    @State private var editingMeetingName = ""
    @State private var didTapInsideMeetingNameEditor = false
    @State private var didTapInsideNotesField = false
    @FocusState private var isMeetingNameFieldFocused: Bool
    @FocusState private var isNotesFieldFocused: Bool

    var body: some View {
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
                viewModel: viewModel
            )

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
                        isListening: viewModel.isListening,
                        showsRecordingIndicator: viewModel.isListening
                            && !viewModel.isBatchRecording
                            && !viewModel.isViewingOtherWhileRecording,
                        showsTranslatedText: appSettings.isTranscriptTranslationEffectivelyEnabled,
                        batchTranscriptionState: viewModel.batchTranscriptionState,
                        confirmBatchTranscription: viewModel.presentBatchTranscriptionConfirmation,
                        retryBatchTranscription: viewModel.retryBatchTranscription,
                        cancelFailedBatchRetranscription: viewModel.cancelFailedBatchRetranscription,
                        discardFailedBatchTranscription: viewModel.discardFailedBatchTranscription,
                        retryInitialMeetingLoad: viewModel.retryInitialMeetingLoad
                    )
                }
            }
            .frame(minHeight: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(tabContentBackgroundColor)
            )

            // エラー表示
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
            }

            if let summaryError = viewModel.summaryError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(summaryError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
            }

            if let googleDocsExportError = viewModel.googleDocsExportError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(googleDocsExportError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
            }

        }
        .padding(28)
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
        .onChange(of: displayedMeetingIdentity) { _, newIdentity in
            if newIdentity != nil {
                selectedTab = initialTabSelection
            }
            viewModel.requestShowSummaryTab = false
            cancelMeetingRename()
            isSelectingScreenshots = false
            selectedScreenshotIds.removeAll()
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
        .overlay {
            if let screenshot = expandedScreenshot {
                ScreenshotOverlayView(screenshot: screenshot) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        expandedScreenshot = nil
                    }
                }
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

    @ViewBuilder
    private var summaryTabContent: some View {
        if let document = viewModel.currentSummaryDocument,
           viewModel.hasCurrentMeetingSummary {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SummaryDocumentView(
                        document: document,
                        imageDataProvider: { screenshotId in
                            guard let record = viewModel.screenshots.first(where: { $0.id == screenshotId }) else { return nil }
                            return record.imageData
                        },
                        transcriptTextProvider: summaryTranscriptText
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label(L10n.summary, systemImage: "list.bullet.clipboard")
            } description: {
                Text(L10n.noSummaryYet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            .foregroundStyle(.tertiary)
                            .padding(NotesEditorLayout.placeholderPadding)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.background)
                )

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func notesEditorHeight(for availableHeight: CGFloat) -> CGFloat {
        let reservedBottomSpace: CGFloat = 96
        let minimumHeight: CGFloat = 140
        let preferredHeight = availableHeight * 0.85
        let maximumHeight = max(minimumHeight, availableHeight - reservedBottomSpace)
        return min(max(minimumHeight, preferredHeight), maximumHeight)
    }

    @ViewBuilder
    private var screenshotsTabContent: some View {
        if viewModel.screenshots.isEmpty {
            ContentUnavailableView {
                Label(L10n.screenshots, systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(L10n.noScreenshotsYet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ScreenshotManagementToolbar(
                    minimumWidth: $screenshotMinimumWidth,
                    isSelecting: $isSelectingScreenshots,
                    selectedCount: selectedScreenshotIds.count,
                    canSelectAll: selectedScreenshotIds.count < deletableScreenshotIds.count,
                    isDeletionDisabled: viewModel.isSummaryGenerating || viewModel.isDeletingScreenshots,
                    selectAll: selectAllScreenshots,
                    deleteSelected: deleteSelectedScreenshots
                )
                .padding(12)

                Divider()

                ScreenshotCollectionView(
                    meetingID: viewModel.currentMeetingId,
                    screenshots: viewModel.screenshots,
                    recordingSessions: viewModel.store.recordingSessions,
                    fallbackTimeBase: screenshotTimeBase,
                    minimumItemWidth: screenshotMinimumWidth,
                    isSelecting: isSelectingScreenshots,
                    referencedScreenshotIDs: referencedScreenshotIds,
                    isDeletionDisabled: viewModel.isSummaryGenerating || viewModel.isDeletingScreenshots,
                    selectedScreenshotIDs: $selectedScreenshotIds,
                    open: openScreenshot,
                    download: viewModel.downloadScreenshot,
                    delete: viewModel.deleteScreenshot
                )
            }
        }
    }

    private func openScreenshot(_ screenshot: MeetingScreenshotRecord) {
        withAnimation(.easeOut(duration: 0.15)) {
            expandedScreenshot = screenshot
        }
    }

    private func selectAllScreenshots() {
        selectedScreenshotIds = deletableScreenshotIds
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

    private var currentMeetingItem: MeetingOverviewItem? {
        guard let meetingId = viewModel.currentMeetingId else { return nil }
        return sidebarViewModel.allMeetings.first(where: { $0.meetingId == meetingId })
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

    private var deletableScreenshotIds: Set<UUID> {
        Set(viewModel.screenshots.map(\.id)).subtracting(referencedScreenshotIds)
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
            return currentMeetingItem.meeting.name
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
            return currentMeetingItem.meeting.id.uuidString
        }
        if let currentMeetingId = viewModel.currentMeetingId {
            return currentMeetingId.uuidString
        }
        if viewModel.hasDraftMeeting {
            return "draft"
        }
        return nil
    }

    private var persistedSummaryExists: Bool {
        currentMeetingItem?.hasSummary == true
    }

    private var hasSummaryTab: Bool {
        persistedSummaryExists || viewModel.hasCurrentMeetingSummary
    }

    private var tabContentBackgroundColor: Color {
        selectedTab == .notes ? Color(nsColor: .textBackgroundColor) : Color(nsColor: .controlBackgroundColor)
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
        if let meeting = currentMeetingItem?.meeting {
            sidebarViewModel.renameMeeting(id: meeting.id, newName: trimmed)
        } else if viewModel.hasDraftMeeting {
            viewModel.updateDraftMeetingTitle(trimmed)
            if let meetingId = viewModel.materializeDraftMeeting() {
                sidebarViewModel.selectMeeting(meetingId)
            }
        }
        isEditingMeetingName = false
        isMeetingNameFieldFocused = false
        didTapInsideMeetingNameEditor = false
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
        hasSummaryTab ? .summary : .notes
    }

}
