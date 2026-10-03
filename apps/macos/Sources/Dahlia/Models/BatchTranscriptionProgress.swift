struct BatchTranscriptionProgress: Equatable, Sendable {
    var isDownloadingArchive = false
    let completedFileCount: Int
    let totalFileCount: Int
}
