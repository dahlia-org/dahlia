import Foundation

extension Duration {
    var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
