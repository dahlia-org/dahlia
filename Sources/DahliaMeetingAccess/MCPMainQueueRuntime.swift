import Foundation

public func runMCPStandardIOWorker(
    _ operation: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable () -> Void
) {
    DispatchQueue.global(qos: .userInitiated).async {
        operation()
        DispatchQueue.main.async(execute: completion)
    }
}
