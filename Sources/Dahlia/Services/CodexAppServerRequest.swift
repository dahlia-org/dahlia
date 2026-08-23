import Foundation

struct CodexAppServerRequest {
    let model: String?
    let requiresExactModel: Bool
    let requiresImageInput: Bool
    let reasoningEffort: String
    let developerInstructions: String
    let inputs: [CodexAppServerInput]
    let outputSchema: Data

    init(
        model: String?,
        requiresExactModel: Bool = false,
        requiresImageInput: Bool = false,
        reasoningEffort: String = CodexReasoningEffortOption.defaultValue,
        developerInstructions: String,
        inputs: [CodexAppServerInput],
        outputSchema: Data
    ) {
        self.model = model
        self.requiresExactModel = requiresExactModel
        self.requiresImageInput = requiresImageInput
        self.reasoningEffort = reasoningEffort
        self.developerInstructions = developerInstructions
        self.inputs = inputs
        self.outputSchema = outputSchema
    }
}
