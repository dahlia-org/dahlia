import SwiftUI

struct ApplicationLogView: View {
    @State private var model = ApplicationLogViewModel()
    @State private var searchText = ""

    private var displayedText: String {
        model.text(matching: searchText)
    }

    var body: some View {
        Group {
            if let errorMessage = model.errorMessage {
                ContentUnavailableView(
                    L10n.applicationLogsUnavailable,
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if !model.hasLogs {
                ContentUnavailableView(
                    L10n.noApplicationLogs,
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(L10n.noApplicationLogsDescription)
                )
            } else if displayedText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(displayedText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding()
                }
            }
        }
        .searchable(text: $searchText, prompt: L10n.searchApplicationLogs)
        .toolbar {
            ToolbarItemGroup {
                Button(
                    L10n.refreshApplicationLogs,
                    systemImage: "arrow.clockwise",
                    action: model.refresh
                )

                Button(
                    L10n.copyDisplayedLogs,
                    systemImage: "doc.on.doc",
                    action: copyDisplayedLogs
                )
                .disabled(displayedText.isEmpty)
            }
        }
        .task {
            model.refresh()
        }
    }

    private func copyDisplayedLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayedText, forType: .string)
    }
}
