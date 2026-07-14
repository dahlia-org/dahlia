import Foundation

enum CodexAppServerInput {
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
}
