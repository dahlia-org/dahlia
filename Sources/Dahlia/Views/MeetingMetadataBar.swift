import SwiftUI

/// ミーティング詳細ヘッダーのメタデータを一つの折り返し行にまとめる。
struct MeetingMetadataBar: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let metadataText: String
    let calendarEvent: CalendarEventDisplayInfo?

    @State private var showTagPopover = false
    @State private var tagInput = ""

    private var tags: [TagInfo] {
        guard let meetingId = viewModel.currentMeetingId,
              let item = sidebarViewModel.selectedMeetingDetail,
              item.meetingId == meetingId else { return [] }
        return item.tags
    }

    private var trimmedTagInput: String {
        tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestions: [TagInfo] {
        let existingNames = Set(tags.map(\.name))
        let availableTags = sidebarViewModel.allAvailableTags.filter { !existingNames.contains($0.name) }
        guard !trimmedTagInput.isEmpty else { return availableTags }
        return availableTags.filter { $0.name.localizedStandardContains(trimmedTagInput) }
    }

    private var shouldShowCreateSuggestion: Bool {
        !trimmedTagInput.isEmpty
            && !tags.contains(where: { $0.name.caseInsensitiveCompare(trimmedTagInput) == .orderedSame })
            && !suggestions.contains(where: { $0.name.caseInsensitiveCompare(trimmedTagInput) == .orderedSame })
    }

    var body: some View {
        FlowLayout(spacing: DahliaDesign.chipSpacing, rowSpacing: DahliaDesign.chipRowSpacing) {
            if let calendarEvent {
                CalendarEventMetadataButton(text: metadataText, event: calendarEvent)
            } else {
                MeetingMetadataPill(systemImage: "calendar", text: metadataText)
            }

            MeetingProjectPicker(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                style: .regular
            )

            ForEach(tags, id: \.name) { tag in
                TagChip(tag: tag) {
                    guard let meetingId = viewModel.currentMeetingId else { return }
                    sidebarViewModel.removeTagFromMeeting(id: meetingId, tag: tag.name)
                }
            }

            addTagButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addTagButton: some View {
        Button {
            tagInput = ""
            showTagPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag.badge.plus")
                    .font(.caption2)
                Text(L10n.addTag)
                    .dahliaFont(.metadata, weight: .medium)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DahliaDesign.chipHorizontalPadding)
            .padding(.vertical, DahliaDesign.chipVerticalPadding)
            .background(
                Capsule()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTagPopover, arrowEdge: .bottom) {
            tagPopoverContent
        }
    }

    private var tagPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(L10n.searchOrCreateTag, text: $tagInput)
                .textFieldStyle(.plain)
                .padding(10)
                .onSubmit {
                    submitTagInput()
                }

            Divider()

            if !suggestions.isEmpty || !tagInput.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.name) { tag in
                            tagSuggestionRow(name: tag.name, colorHex: tag.colorHex, isNew: false)
                        }

                        if shouldShowCreateSuggestion {
                            tagSuggestionRow(name: trimmedTagInput, colorHex: nil, isNew: true)
                        }
                    }
                }
                .frame(maxHeight: 240)
            } else {
                // 既存タグが無くて入力もない場合
                VStack {
                    Spacer()
                    Text(L10n.noResultsFound)
                        .dahliaFont(.body)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            }
        }
        .frame(width: 240)
    }

    private func tagSuggestionRow(name: String, colorHex: String?, isNew: Bool) -> some View {
        Button {
            guard let meetingId = ensureMeetingId() else { return }
            sidebarViewModel.addTagToMeeting(id: meetingId, tag: name)
            sidebarViewModel.selectMeeting(meetingId)
            tagInput = ""
        } label: {
            HStack(spacing: 6) {
                if isNew {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(Color(hex: colorHex ?? "#808080"))
                        .frame(width: 8, height: 8)
                }
                Text(name)
                    .dahliaFont(.body)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
    }

    private func submitTagInput() {
        guard !trimmedTagInput.isEmpty else { return }
        guard let meetingId = ensureMeetingId() else { return }
        sidebarViewModel.addTagToMeeting(id: meetingId, tag: trimmedTagInput.localizedLowercase)
        sidebarViewModel.selectMeeting(meetingId)
        tagInput = ""
    }

    private func ensureMeetingId() -> UUID? {
        if let meetingId = viewModel.currentMeetingId {
            return meetingId
        }
        return viewModel.materializeDraftMeeting(
            customerIntelligenceIngestion: .afterMeetingPersistence
        )
    }
}

private struct MeetingMetadataPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .dahliaFont(.metadata, weight: .medium)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .dahliaChipSurface()
    }
}

// MARK: - Tag Chip

private struct TagChip: View {
    let tag: TagInfo
    let onRemove: () -> Void

    @State private var isHovered = false
    @FocusState private var isRemoveFocused: Bool

    private var showsRemoveButton: Bool {
        isHovered || isRemoveFocused
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Color(hex: tag.colorHex))
                    .opacity(showsRemoveButton ? 0 : 1)

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, minHeight: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($isRemoveFocused)
                .opacity(showsRemoveButton ? 1 : 0)
                .allowsHitTesting(showsRemoveButton)
                .accessibilityLabel(L10n.delete)
            }
            .frame(width: 16, height: 16)

            Text(tag.name)
                .dahliaFont(.metadata, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .dahliaChipSurface(isHovered: isHovered, tint: Color(hex: tag.colorHex))
        .frame(maxWidth: 220)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(L10n.delete, role: .destructive, action: onRemove)
        }
        .accessibilityAction(named: Text(L10n.delete), onRemove)
    }
}
