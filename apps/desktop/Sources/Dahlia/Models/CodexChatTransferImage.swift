import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct CodexChatTransferImage: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            Self(data: data)
        }
    }
}
