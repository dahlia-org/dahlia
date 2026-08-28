import SwiftUI

/// ミーティング詳細のタイトル。クリックでインライン編集できる。
private struct MeetingNameHeader: View {
    let title: String
    let meetingID: UUID?
    @Binding var isEditing: Bool
    @Binding var editingName: String
    @FocusState.Binding var isFocused: Bool
    let onBeginEditing: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onEditorTap: () -> Void
    @State private var isNameHovered = false
    @State private var isCopyHovered = false
    @State private var copyCount = 0
    @FocusState private var isNameFocused: Bool

    private var displayName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.newMeeting : trimmed
    }

    var body: some View {
        Group {
            if isEditing {
                TextField(L10n.title, text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.title)
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
                HStack(spacing: 4) {
                    Button(action: onBeginEditing) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(.title)
                                .foregroundStyle(DahliaDesign.primaryTextColor)
                                .lineLimit(2)
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DahliaDesign.optionalTextColor)
                                .opacity(isNameHovered || isNameFocused ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($isNameFocused)
                    .onHover { hovering in
                        isNameHovered = hovering
                    }
                    .help(L10n.rename)

                    if meetingID != nil {
                        Button(action: copyMeetingID) {
                            Label(L10n.copyMeetingID, systemImage: "square.on.square")
                                .labelStyle(.iconOnly)
                                .symbolEffect(.bounce, options: .speed(1.5), value: copyCount)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DahliaDesign.optionalTextColor)
                        .background(
                            isCopyHovered ? DahliaDesign.contentHighlightColor : .clear,
                            in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                        )
                        .onHover { isCopyHovered = $0 }
                        .dahliaHoverHelp(label: L10n.copyMeetingID)
                        .accessibilityHint(Text(verbatim: L10n.copyMeetingIDHint))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: title) { _, newTitle in
            isEditing = false
            editingName = newTitle
        }
    }

    private func copyMeetingID() {
        guard let meetingID else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meetingID.uuidString, forType: .string)
        copyCount += 1
    }
}

struct MeetingDetailHeader: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
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
            HStack(spacing: 16) {
                MeetingNameHeader(
                    title: title,
                    meetingID: viewModel.currentMeetingId,
                    isEditing: $isEditing,
                    editingName: $editingName,
                    isFocused: $isFocused,
                    onBeginEditing: onBeginEditing,
                    onCommit: onCommit,
                    onCancel: onCancel,
                    onEditorTap: onEditorTap
                )

                HStack(spacing: 4) {
                    HStack(spacing: 0) {
                        GenerateSummaryHeaderButton(
                            viewModel: viewModel,
                            sidebarViewModel: sidebarViewModel
                        )
                        ShareSummaryHeaderButton(viewModel: viewModel)
                    }

                    if showsRecordButton {
                        RecordButton(
                            viewModel: viewModel,
                            sidebarViewModel: sidebarViewModel,
                            recordingCoordinator: recordingCoordinator
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            MeetingMetadataBar(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                metadataText: metadataText,
                calendarEvent: calendarEvent
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 2)
    }

    private var showsRecordButton: Bool {
        RecordingCommandState.showsDetailCommand(
            isShowingSettings: mainWindowNavigation.isShowingSettings,
            isListening: viewModel.isListening,
            recordingMeetingID: viewModel.recordingMeetingId,
            currentMeetingID: viewModel.currentMeetingId
        )
    }
}
