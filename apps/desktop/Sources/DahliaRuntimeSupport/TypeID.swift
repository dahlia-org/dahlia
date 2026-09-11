import Foundation

/// Public representation only; persistence and domain models continue to use UUID.
public enum TypeID {
    public enum Kind: String, CaseIterable, Sendable {
        case vault = "vlt", project = "proj", meeting = "mtg", file, attachment = "att"
        case summary = "sum", transcript, segment = "seg", recording = "rec", event = "evt"
        case summaryJob = "sjob"
        case user, organization = "org", team, organizationMember = "omem", teamMember = "tmem"
        case invitation = "inv", session = "sess", transaction = "txn", operation = "op", patch
    }

    public enum Failure: Error { case invalidID }

    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz".utf8)

    public static func encode(_ uuid: UUID, as kind: Kind) -> String {
        var bytes = uuid.uuid
        let source = withUnsafeBytes(of: &bytes) { Array($0) }
        var output: [UInt8] = []
        var accumulator = 0
        var bits = 2
        for byte in source {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(accumulator >> bits) & 31])
            }
            accumulator &= (1 << bits) - 1
        }
        return kind.rawValue + "_" + String(decoding: output, as: UTF8.self)
    }

    public static func decode(_ value: String, as kind: Kind) throws -> UUID {
        let prefix = kind.rawValue + "_"
        guard value.hasPrefix(prefix) else { throw Failure.invalidID }
        let suffix = Array(value.dropFirst(prefix.count).utf8)
        guard suffix.count == 26, let first = suffix.first, first >= 48, first <= 55 else { throw Failure.invalidID }
        var output: [UInt8] = []
        var accumulator = 0
        var bits = -2
        for character in suffix {
            guard let digit = alphabet.firstIndex(of: character) else { throw Failure.invalidID }
            accumulator = (accumulator << 5) | digit
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> bits) & 255))
            }
            if bits >= 0 { accumulator &= (1 << bits) - 1 }
        }
        return UUID(uuid: (
            output[0],
            output[1],
            output[2],
            output[3],
            output[4],
            output[5],
            output[6],
            output[7],
            output[8],
            output[9],
            output[10],
            output[11],
            output[12],
            output[13],
            output[14],
            output[15]
        ))
    }
}
