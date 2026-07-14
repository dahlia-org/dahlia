import Foundation

struct CodexAppServerRequest {
    let model: String?
    let reasoningEffort: String
    let developerInstructions: String
    let inputs: [CodexAppServerInput]
    let outputSchema: Data

    init(
        model: String?,
        reasoningEffort: String = CodexReasoningEffortOption.defaultValue,
        developerInstructions: String,
        inputs: [CodexAppServerInput],
        outputSchema: Data
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.developerInstructions = developerInstructions
        self.inputs = inputs
        self.outputSchema = outputSchema
    }
}
