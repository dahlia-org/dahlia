import DahliaLindera

/// Keeps the validated dictionary available to tokenizers without loading it inside a database write.
public final class PreparedSearchDictionary {
    private let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        dahlia_lindera_delete(handle)
    }
}
