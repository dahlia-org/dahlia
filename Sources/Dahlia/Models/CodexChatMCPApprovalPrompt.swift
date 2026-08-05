struct CodexChatMCPApprovalPrompt: Equatable, Sendable {
    private static let allowedOptionLabels: Set = [
        "Allow",
        "Allow for this session",
        "Allow and don't ask me again",
        "Cancel",
    ]

    let itemID: String
    let questionID: String

    init?(params: [String: JSONValue]) {
        guard params["autoResolutionMs"] == nil || params["autoResolutionMs"] == .null,
              let itemID = params["itemId"]?.stringValue?.nilIfBlank,
              let questions = params["questions"]?.arrayValue,
              questions.count == 1,
              let question = questions.first?.objectValue,
              let questionID = question["id"]?.stringValue,
              questionID == "mcp_tool_call_approval_\(itemID)",
              question["header"]?.stringValue == "Approve app tool call?",
              question["question"]?.stringValue?.nilIfBlank != nil,
              question["isOther"]?.boolValue != true,
              question["isSecret"]?.boolValue != true,
              let options = question["options"]?.arrayValue,
              Self.hasExpectedOptions(options)
        else { return nil }
        self.itemID = itemID
        self.questionID = questionID
    }

    private static func hasExpectedOptions(_ values: [JSONValue]) -> Bool {
        let labels = values.compactMap { value -> String? in
            guard let option = value.objectValue,
                  option["description"]?.stringValue != nil else { return nil }
            return option["label"]?.stringValue
        }
        let uniqueLabels = Set(labels)
        return labels.count == values.count
            && uniqueLabels.isSubset(of: allowedOptionLabels)
            && labels.count == uniqueLabels.count
            && labels.contains("Allow")
            && labels.contains("Cancel")
    }
}
