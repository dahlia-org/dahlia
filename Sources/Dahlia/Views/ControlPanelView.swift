import AppKit
import ImageIO
import SwiftUI

private extension View {
    @ViewBuilder
    func actionCursor(isEnabled: Bool = true) -> some View {
        if isEnabled {
            self.pointerStyle(.link)
        } else {
            self
        }
    }
}

private enum NotesEditorLayout {
    static let editorPadding = EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
    /// `TextEditor` keeps a small internal inset on macOS, so the placeholder needs
    /// a matching offset instead of using the same outer padding.
    static let placeholderPadding = EdgeInsets(top: 10, leading: 9, bottom: 0, trailing: 0)
}

private enum ObsidianLauncher {
    private static let bundleIdentifier = "md.obsidian"

    static let isInstalled: Bool =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil

    static func open(_ url: URL) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]

        guard let obsidianURL = components.url else { return }
        NSWorkspace.shared.open(obsidianURL)
    }
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

/// タイトルバー / ツールバーに表示する詳細タブ切り替え。
private struct DetailTabBar: View {
    @Binding var selection: DetailTab
    @ObservedObject var viewModel: CaptionViewModel

    /// フォルダ選択時（transcription 未選択）は全タブを無効化する。
    /// 録音中は録音対象が存在するためタブを無効化しない。
    private var isFolderOnly: Bool {
        viewModel.currentMeetingId == nil && !viewModel.isListening && !viewModel.hasDraftMeeting
    }

    private var visibleTabs: [DetailTab] {
        DetailTab.allCases
    }

    var body: some View {
        Picker(L10n.transcript, selection: $selection) {
            ForEach(visibleTabs) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .disabled(isFolderOnly)
        .frame(minWidth: 280)
    }
}

/// スクリーンショット拡大表示オーバーレイ。
private struct ScreenshotOverlayView: View {
    let image: NSImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel(L10n.close)

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 20)
                .padding(24)

            Button(L10n.close, systemImage: "xmark.circle.fill", action: onDismiss)
                .labelStyle(.iconOnly)
                .font(.title3)
                .padding(16)
                .buttonStyle(.plain)
                .pointerStyle(.link)
        }
    }
}

/// スクリーンショットのサムネイル表示。
private struct ScreenshotThumbnailView: View {
    let screenshot: MeetingScreenshotRecord
    let timestamp: String
    let viewModel: CaptionViewModel
    @Binding var expandedScreenshot: MeetingScreenshotRecord?
    @State private var thumbnailImage: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            if let thumbnailImage {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        expandedScreenshot = screenshot
                    }
                } label: {
                    Image(decorative: thumbnailImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityLabel(L10n.open)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .accessibilityHidden(true)
            }
            HStack {
                Text(timestamp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.delete, systemImage: "trash", role: .destructive) {
                    viewModel.deleteScreenshot(screenshot)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
        .task(id: screenshot.id) {
            thumbnailImage = nil
            thumbnailImage = await Self.makeThumbnail(from: screenshot.imageData)
        }
    }

    private nonisolated static func makeThumbnail(from data: Data) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 600,
            ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
        }.value
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

    var body: some View {
        Menu {
            Button {
                guard let summaryURL = viewModel.lastSummaryURL else { return }
                ObsidianLauncher.open(summaryURL)
            } label: {
                Label(L10n.openInObsidian, systemImage: "book.closed")
            }
            .disabled(viewModel.lastSummaryURL == nil || !ObsidianLauncher.isInstalled)

            Button {
                guard let browserURL = viewModel.currentSummaryGoogleFileURL else { return }
                NSWorkspace.shared.open(browserURL)
            } label: {
                Label(L10n.openInBrowser, systemImage: "globe")
            }
            .disabled(viewModel.currentSummaryGoogleFileURL == nil)

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
                MeetingMetadataPill(systemImage: "calendar", text: metadataText)

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
        MeetingActionsMenu(viewModel: viewModel, sidebarViewModel: sidebarViewModel)
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
                    isEditing: $isEditingMeetingName,
                    editingName: $editingMeetingName,
                    isFocused: $isMeetingNameFieldFocused,
                    onBeginEditing: beginMeetingRename,
                    onCommit: commitMeetingRename,
                    onCancel: cancelMeetingRename,
                    onEditorTap: markMeetingNameEditorTap
                )
            }

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
                        discardFailedBatchTranscription: viewModel.discardFailedBatchTranscription
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

            if let summaryWarning = viewModel.summaryWarning {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(summaryWarning)
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
        .onChange(of: displayedMeetingIdentity) { _, newIdentity in
            if newIdentity != nil {
                selectedTab = initialTabSelection
            }
            viewModel.requestShowSummaryTab = false
            cancelMeetingRename()
        }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.summaryProgress.isVisible {
                SummaryProgressToastView(state: viewModel.summaryProgress)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: viewModel.summaryProgress.isVisible)
            }
        }
        .overlay {
            if let screenshot = expandedScreenshot,
               let nsImage = NSImage(data: screenshot.imageData) {
                ScreenshotOverlayView(image: nsImage) {
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
        ToolbarItem(placement: .principal) {
            DetailTabBar(selection: $selectedTab, viewModel: viewModel)
        }

        ToolbarItem(placement: .primaryAction) {
            if showsToolbarRecordButton {
                SummaryToolbarControlGroup(
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
                    HStack(spacing: 12) {
                        Button {
                            guard let summaryURL = viewModel.lastSummaryURL else { return }
                            ObsidianLauncher.open(summaryURL)
                        } label: {
                            Label(L10n.openInObsidian, systemImage: "book.closed")
                        }
                        .disabled(viewModel.lastSummaryURL == nil || !ObsidianLauncher.isInstalled)
                        .actionCursor(isEnabled: viewModel.lastSummaryURL != nil && ObsidianLauncher.isInstalled)

                        Button {
                            guard let browserURL = viewModel.currentSummaryGoogleFileURL else { return }
                            NSWorkspace.shared.open(browserURL)
                        } label: {
                            Label(L10n.openInBrowser, systemImage: "globe")
                        }
                        .disabled(viewModel.currentSummaryGoogleFileURL == nil)
                        .actionCursor(isEnabled: viewModel.currentSummaryGoogleFileURL != nil)

                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.bordered)

                    SummaryDocumentView(
                        document: document,
                        imageProvider: { screenshotId in
                            guard let record = viewModel.screenshots.first(where: { $0.id == screenshotId }) else { return nil }
                            return NSImage(data: record.imageData)
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
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    let timeBase = screenshotTimeBase
                    let recordingSessions = viewModel.store.recordingSessions
                    ForEach(viewModel.screenshots, id: \.id) { screenshot in
                        ScreenshotThumbnailView(
                            screenshot: screenshot,
                            timestamp: Formatters.elapsedHHmmss(
                                at: screenshot.capturedAt,
                                sessionId: screenshot.sessionId,
                                sessions: recordingSessions,
                                fallbackTimeBase: timeBase
                            ),
                            viewModel: viewModel,
                            expandedScreenshot: $expandedScreenshot
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Computed

    private var currentMeetingItem: MeetingOverviewItem? {
        guard let meetingId = viewModel.currentMeetingId else { return nil }
        return sidebarViewModel.allMeetings.first(where: { $0.meetingId == meetingId })
    }

    private var screenshotTimeBase: Date {
        viewModel.store.timeBase
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
        !viewModel.isListening || viewModel.recordingMeetingId == viewModel.currentMeetingId
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
