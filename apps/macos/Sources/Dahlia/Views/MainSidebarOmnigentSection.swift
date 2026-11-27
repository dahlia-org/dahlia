import SwiftUI

/// The Databricks workspace's Omnigent sessions in the Chat sidebar's `List`, shown for the connection Omnigent is on for.
/// A row opens the session's conversation in the main area.
struct MainSidebarOmnigentSection: View {
    let connectionID: UUID
    let selectedSessionID: String?
    let onOpen: (String) -> Void
    @State private var isExpanded = true
    @State private var sessions: [OmnigentService.Session] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var revision = 0

    init(connectionID: UUID, selectedSessionID: String?, onOpen: @escaping (String) -> Void) {
        self.connectionID = connectionID
        self.selectedSessionID = selectedSessionID
        self.onOpen = onOpen
    }

    var body: some View {
        MeetingSidebarHeader(
            title: L10n.omnigent,
            isExpanded: isExpanded,
            onToggleExpansion: { isExpanded.toggle() },
            icon: OmnigentLogo.image,
            addButtonTitle: L10n.omnigentRefresh,
            addButtonSystemImage: "arrow.clockwise",
            canAdd: !isLoading,
            onAdd: { revision += 1 }
        )
        .listRowSeparator(.hidden)
        // Chat can start sessions and they finish on their own, so the list refreshes while it is shown.
        .task(id: "\(revision)-\(isExpanded)") {
            // A collapsed section shows no rows, so it does not poll; expanding reloads.
            while isExpanded, !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }

        if isExpanded {
            ForEach(sessions) { session in
                Button { onOpen(session.id) } label: {
                    HStack(spacing: 8) {
                        Text(session.title?.nilIfBlank ?? session.id).lineLimit(1)
                        Spacer(minLength: 8)
                        switch session.status {
                        case "running", "waiting", "launching":
                            ProgressView().controlSize(.small).accessibilityLabel(L10n.chatThreadRunning)
                        case "failed":
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .accessibilityLabel(L10n.chatRunStatus("failed"))
                        default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(.rect)
                    .modifier(SidebarNavigationRowModifier(isSelected: session.id == selectedSessionID))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(session.id == selectedSessionID ? .isSelected : [])
                }
                .buttonStyle(.plain)
                .listRowInsets(.vertical, 1.5)
                .listRowSeparator(.hidden)
            }
            statusRow
                .listRowInsets(.vertical, 1.5)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if isLoading, sessions.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error)
                    .lineLimit(3)
                    .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
                Button(L10n.retry) { revision += 1 }
            }
        } else if sessions.isEmpty, !isLoading {
            Text(L10n.omnigentNoSessions)
                .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let sessions = try await OmnigentService.sessions(connectionID: connectionID)
            guard !Task.isCancelled else { return }
            self.sessions = sessions
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
