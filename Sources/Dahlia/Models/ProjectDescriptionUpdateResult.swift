enum ProjectDescriptionUpdateResult: Equatable {
    case saved
    case projectNotFound
    case staleRevision(current: Int)
    case failed
}
