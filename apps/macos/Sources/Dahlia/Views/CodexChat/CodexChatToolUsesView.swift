import SwiftUI

struct CodexChatToolUsesView: View {
    let activities: [CodexChatToolActivity]
    @State private var isExpanded = false

    var body: some View {
        if activities.count == 1, let activity = activities.first {
            CodexChatToolActivityRow(activity: activity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button { isExpanded.toggle() } label: {
                    CodexChatStepRowLabel(symbol: "hammer", isExpanded: isExpanded) {
                        Text(L10n.chatToolUseCount(activities.count))
                    }
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(activities.indices, id: \.self) { index in
                            CodexChatToolActivityRow(activity: activities[index])
                        }
                    }
                    .padding(.leading, CodexChatDesign.stepContentInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A tool call that opens to its input and output.
private struct CodexChatToolActivityRow: View {
    let activity: CodexChatToolActivity
    @State private var isExpanded = false

    var body: some View {
        let hasPayload = activity.input != nil || activity.output != nil
        VStack(alignment: .leading, spacing: 6) {
            Button { if hasPayload { isExpanded.toggle() } } label: {
                CodexChatStepRowLabel(symbol: activity.toolSymbol, isExpanded: hasPayload ? isExpanded : nil) {
                    Text([activity.name, activity.detail].compactMap(\.self).joined(separator: " "))
                        .lineLimit(1)
                        .help(activity.detail ?? activity.name)
                    if activity.status == .failed || activity.status == .inaccessible {
                        Image(systemName: activity.symbol)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(activity.text)
                    }
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(hasPayload ? .link : nil)
            .accessibilityHint(hasPayload ? (isExpanded ? L10n.collapse : L10n.expand) : "")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = activity.input {
                        Text(input)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if activity.input != nil, activity.output != nil {
                        Divider()
                    }
                    if let output = activity.output {
                        // Output can be long; keep the conversation scrollable around it.
                        ScrollView {
                            Text(output)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 240)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.dahliaSecondary.monospaced())
                .padding(10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: DahliaDesign.Field.cornerRadius))
                .padding(.leading, CodexChatDesign.stepContentInset)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
