import Foundation

enum CodexAppServerInput: Equatable, Sendable {
    case text(String)
    case imageMetadata(String)
    case imageDataURI(String)

    var isImage: Bool {
        if case .imageDataURI = self { true } else { false }
    }

    var isImageRelated: Bool {
        switch self {
        case .imageMetadata, .imageDataURI: true
        case .text: false
        }
    }

    var textValue: String? {
        switch self {
        case let .text(text), let .imageMetadata(text): text
        case .imageDataURI: nil
        }
    }
}
