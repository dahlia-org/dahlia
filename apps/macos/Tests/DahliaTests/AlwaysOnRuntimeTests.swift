#if canImport(Testing)
    import Testing

    /// Bot runtime fixtures share the app account's standing settings.
    @Suite(.serialized)
    struct AlwaysOnRuntimeTests {}
#endif
