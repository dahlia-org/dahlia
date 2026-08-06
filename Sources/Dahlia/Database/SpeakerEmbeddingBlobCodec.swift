import Foundation

enum SpeakerEmbeddingBlobCodecError: Error, Equatable {
    case invalidFormat
    case unsupportedVersion
    case wrongByteCount
    case wrongDimension
    case invalidEmbedding
}

enum SpeakerEmbeddingBlobCodec {
    static let formatVersion: UInt16 = 1
    private static let magic: [UInt8] = [0x44, 0x53, 0x45, 0x46] // DSEF
    private static let headerByteCount = 12

    static func encode(_ values: [Float], dimensionCount: Int) throws -> Data {
        guard dimensionCount == SpeakerEmbeddingValidation.dimensionCount,
              values.count == dimensionCount
        else {
            throw SpeakerEmbeddingBlobCodecError.wrongDimension
        }
        guard let normalized = SpeakerEmbeddingValidation.normalizedChunk(values) else {
            throw SpeakerEmbeddingBlobCodecError.invalidEmbedding
        }

        var data = Data(magic)
        appendLittleEndian(formatVersion, to: &data)
        appendLittleEndian(UInt16.zero, to: &data)
        appendLittleEndian(UInt32(dimensionCount), to: &data)
        for value in normalized {
            appendLittleEndian(value.bitPattern, to: &data)
        }
        return data
    }

    static func decode(_ data: Data, dimensionCount: Int) throws -> [Float] {
        guard data.count >= headerByteCount,
              Array(data.prefix(magic.count)) == magic
        else {
            throw SpeakerEmbeddingBlobCodecError.invalidFormat
        }
        guard readUInt16(data, offset: 4) == formatVersion else {
            throw SpeakerEmbeddingBlobCodecError.unsupportedVersion
        }
        guard readUInt16(data, offset: 6) == 0 else {
            throw SpeakerEmbeddingBlobCodecError.invalidFormat
        }
        let storedDimension = Int(readUInt32(data, offset: 8))
        guard storedDimension == dimensionCount,
              dimensionCount == SpeakerEmbeddingValidation.dimensionCount
        else {
            throw SpeakerEmbeddingBlobCodecError.wrongDimension
        }
        guard data.count == headerByteCount + dimensionCount * MemoryLayout<Float>.size else {
            throw SpeakerEmbeddingBlobCodecError.wrongByteCount
        }

        let values = (0 ..< dimensionCount).map { index in
            Float(bitPattern: readUInt32(data, offset: headerByteCount + index * MemoryLayout<Float>.size))
        }
        guard let normalized = SpeakerEmbeddingValidation.normalizedChunk(values) else {
            throw SpeakerEmbeddingBlobCodecError.invalidEmbedding
        }
        return normalized
    }

    private static func appendLittleEndian(_ value: some FixedWidthInteger, to data: inout Data) {
        let littleEndian = value.littleEndian
        withUnsafeBytes(of: littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        let index = data.startIndex + offset
        return UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let index = data.startIndex + offset
        return UInt32(data[index])
            | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16
            | UInt32(data[index + 3]) << 24
    }
}
