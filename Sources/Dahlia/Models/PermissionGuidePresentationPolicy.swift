enum PermissionGuidePresentationPolicy {
    static let userDefaultsKey = "permissionGuidePresentationVersion"
    static let currentVersion = 1

    static func shouldPresent(storedVersion: Int) -> Bool {
        storedVersion < currentVersion
    }
}
