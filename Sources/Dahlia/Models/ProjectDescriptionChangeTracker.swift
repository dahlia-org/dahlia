struct ProjectDescriptionChangeTracker: Equatable {
    private var programmaticValue: String?

    mutating func prepareForProgrammaticChange(from currentValue: String, to newValue: String) {
        programmaticValue = currentValue == newValue ? nil : newValue
    }

    mutating func shouldSaveChange(to newValue: String) -> Bool {
        let shouldSave = programmaticValue != newValue
        programmaticValue = nil
        return shouldSave
    }
}
