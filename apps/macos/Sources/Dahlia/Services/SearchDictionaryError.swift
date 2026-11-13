import Foundation

enum SearchDictionaryError: LocalizedError, Equatable {
    case catalogUnavailable, downloadFailed, checksumMismatch, invalidDictionary, invalidUserDictionary

    var errorDescription: String? {
        switch self {
        case .catalogUnavailable: L10n.searchNeologdCatalogUnavailable
        case .downloadFailed: L10n.searchDictionaryDownloadFailed
        case .checksumMismatch: L10n.searchDictionaryChecksumMismatch
        case .invalidDictionary: L10n.searchDictionaryInvalid
        case .invalidUserDictionary: L10n.searchUserDictionaryInvalid
        }
    }
}
