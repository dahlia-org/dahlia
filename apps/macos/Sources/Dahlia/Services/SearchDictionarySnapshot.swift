import DahliaMeetingAccess

struct SearchDictionarySnapshot: Sendable {
    let preferred: SearchDictionaryConfiguration
    let active: SearchDictionaryConfiguration
    let neologdReleases: [SearchNeologdRelease]
    let installedNeologdIDs: Set<String>
    let userDictionaryPath: String
    let userDictionaryError: String?
}
