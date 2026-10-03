import SwiftUI

struct MainSearchTokenRow: View {
    let tokens: [MeetingSearchToken]
    let projects: [FlatProjectRow]
    let tags: [TagRecord]
    let onRemove: (MeetingSearchToken) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tokens) { token in
                    Button {
                        onRemove(token)
                    } label: {
                        HStack(spacing: 4) {
                            MeetingSearchTokenLabel(token: token, projects: projects, tags: tags)
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.removeSearchFilter)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
