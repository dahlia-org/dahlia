import Foundation

@MainActor
final class CodexChatTurnAccumulator {
    private var responseItemIDs: [String] = []
    private var responseTexts: [String: String] = [:]
    private var reasoningItemIDs: [String] = []
    private var reasoningSections: [String: [Int: String]] = [:]

    var responseText: String {
        responseItemIDs.compactMap { responseTexts[$0]?.nilIfBlank }.joined(separator: "\n\n")
    }

    var reasoningText: String {
        reasoningItemIDs.compactMap { itemID in
            reasoningSections[itemID]?
                .sorted { $0.key < $1.key }
                .compactMap(\.value.nilIfBlank)
                .joined(separator: "\n\n")
                .nilIfBlank
        }
        .joined(separator: "\n\n")
    }

    func appendResponseDelta(itemID: String, text: String) {
        registerResponseItem(itemID)
        responseTexts[itemID, default: ""] += text
    }

    func completeResponse(itemID: String, text: String?) {
        registerResponseItem(itemID)
        if let text {
            responseTexts[itemID] = text
        }
    }

    func appendReasoningDelta(itemID: String, summaryIndex: Int, text: String) {
        registerReasoningItem(itemID)
        reasoningSections[itemID, default: [:]][summaryIndex, default: ""] += text
    }

    func completeReasoning(itemID: String, text: String) {
        registerReasoningItem(itemID)
        if let text = text.nilIfBlank {
            reasoningSections[itemID] = [0: text]
        }
    }

    private func registerResponseItem(_ itemID: String) {
        guard responseTexts[itemID] == nil else { return }
        responseItemIDs.append(itemID)
        responseTexts[itemID] = ""
    }

    private func registerReasoningItem(_ itemID: String) {
        guard reasoningSections[itemID] == nil else { return }
        reasoningItemIDs.append(itemID)
        reasoningSections[itemID] = [:]
    }
}
