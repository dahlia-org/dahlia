import Foundation

struct CodexAppServerDahliaMCPConfiguration: Equatable {
    let executableURL: URL
    let vaultID: UUID
    let allowedMeetingIDs: [UUID]
}

struct CodexAppServerRequest {
    let model: String?
    let reasoningEffort: String
    let developerInstructions: String
    let inputs: [CodexAppServerInput]
    let outputSchema: Data
    let dahliaMCP: CodexAppServerDahliaMCPConfiguration?

    init(
        model: String?,
        reasoningEffort: String = CodexReasoningEffortOption.defaultValue,
        developerInstructions: String,
        inputs: [CodexAppServerInput],
        outputSchema: Data,
        dahliaMCP: CodexAppServerDahliaMCPConfiguration? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.developerInstructions = developerInstructions
        self.inputs = inputs
        self.outputSchema = outputSchema
        self.dahliaMCP = dahliaMCP
    }
}
