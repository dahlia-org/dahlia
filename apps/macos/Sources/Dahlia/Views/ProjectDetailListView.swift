import SwiftUI

struct ProjectDetailListView: View {
    let items: [MeetingSidebarItem]
    let isLoading: Bool
    let hasMore: Bool
    let isLimited: Bool
    let error: String?
    let onOpenMeeting: (UUID) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        if items.isEmpty, isLoading {
            ProgressView(L10n.loadingMeetings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty, let error {
            ContentUnavailableView {
                Label(L10n.meetingListLoadFailed, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(L10n.retry, action: onLoadMore)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            ContentUnavailableView(L10n.noMeetingsInProject, systemImage: "calendar.badge.clock")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button(action: { onOpenMeeting(item.meetingId) }) {
                            ProjectDetailMeetingRow(item: item)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }

                    if let error {
                        Button(L10n.retry, systemImage: "arrow.clockwise", action: onLoadMore)
                            .help(error)
                            .padding()
                    } else if isLoading {
                        ProgressView()
                            .padding()
                    } else if hasMore {
                        Button(L10n.loadMore, action: onLoadMore)
                            .padding()
                    } else if isLimited {
                        Text(L10n.projectMeetingLimitReached)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }
        }
    }
}

struct ProjectDetailMeetingRow: View {
    let item: MeetingSidebarItem

    var body: some View {
        HStack(spacing: 12) {
            Text(item.displayTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.effectiveRecordingStartedAt.formatted(date: .long, time: .omitted))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
