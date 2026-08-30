struct CodexChatUserInputRequest: Identifiable, Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        let label: String
        let description: String

        var id: String { label }
    }

    let id: String
    let questionID: String
    let header: String
    let question: String
    let options: [Option]
    let allowsOther: Bool

    init?(id: String, params: [String: JSONValue]) {
        guard params["autoResolutionMs"] == nil || params["autoResolutionMs"] == .null,
              params["isBlocking"]?.boolValue != nil,
              let questions = params["questions"]?.arrayValue,
              questions.count == 1,
              let value = questions.first?.objectValue,
              value["isSecret"]?.boolValue != true,
              let questionID = value["id"]?.stringValue?.nilIfBlank,
              let header = value["header"]?.stringValue?.nilIfBlank,
              let question = value["question"]?.stringValue?.nilIfBlank,
              let optionValues = value["options"]?.arrayValue,
              (1 ... 3).contains(optionValues.count),
              questionID.count <= 120,
              header.count <= 120,
              question.count <= 500
        else { return nil }
        let options = optionValues.compactMap { option -> Option? in
            guard let object = option.objectValue,
                  let label = object["label"]?.stringValue?.nilIfBlank,
                  let description = object["description"]?.stringValue?.nilIfBlank,
                  label.count <= 120,
                  description.count <= 500 else { return nil }
            return Option(label: label, description: description)
        }
        guard options.count == optionValues.count,
              Set(options.map(\.label)).count == options.count else { return nil }
        self.id = id
        self.questionID = questionID
        self.header = header
        self.question = question
        self.options = options
        self.allowsOther = value["isOther"]?.boolValue == true
    }
}
