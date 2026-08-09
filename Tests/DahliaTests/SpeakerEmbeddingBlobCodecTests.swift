import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SpeakerEmbeddingBlobCodecTests {
        @Test
        func roundTripsVersionedLittleEndianFloat32() throws {
            let values = unitVector(index: 0)
            let blob = try SpeakerEmbeddingBlobCodec.encode(values, dimensionCount: values.count)

            #expect(Array(blob.prefix(4)) == [0x44, 0x53, 0x45, 0x46])
            #expect(Array(blob[4 ..< 6]) == [1, 0])
            #expect(Array(blob[8 ..< 12]) == [0, 1, 0, 0])
            #expect(Array(blob[12 ..< 16]) == [0, 0, 0x80, 0x3F])
            #expect(try SpeakerEmbeddingBlobCodec.decode(blob, dimensionCount: values.count) == values)
        }

        @Test
        func rejectsCorruptionNonFiniteWrongDimensionAndWrongVersion() throws {
            let values = unitVector(index: 4)
            let blob = try SpeakerEmbeddingBlobCodec.encode(values, dimensionCount: values.count)

            #expect(throws: SpeakerEmbeddingBlobCodecError.wrongByteCount) {
                try SpeakerEmbeddingBlobCodec.decode(blob.dropLast(), dimensionCount: values.count)
            }
            var nonFinite = blob
            nonFinite.replaceSubrange(12 ..< 16, with: [0, 0, 0xC0, 0x7F])
            #expect(throws: SpeakerEmbeddingBlobCodecError.invalidEmbedding) {
                try SpeakerEmbeddingBlobCodec.decode(nonFinite, dimensionCount: values.count)
            }
            #expect(throws: SpeakerEmbeddingBlobCodecError.wrongDimension) {
                try SpeakerEmbeddingBlobCodec.decode(blob, dimensionCount: values.count - 1)
            }
            var wrongVersion = blob
            wrongVersion[4] = 2
            #expect(throws: SpeakerEmbeddingBlobCodecError.unsupportedVersion) {
                try SpeakerEmbeddingBlobCodec.decode(wrongVersion, dimensionCount: values.count)
            }
            var wrongMagic = blob
            wrongMagic[0] = 0
            #expect(throws: SpeakerEmbeddingBlobCodecError.invalidFormat) {
                try SpeakerEmbeddingBlobCodec.decode(wrongMagic, dimensionCount: values.count)
            }
            let prefixedWrongVersion = Data(repeating: 0, count: 16) + wrongVersion
            let slicedWrongVersion = prefixedWrongVersion.dropFirst(16)
            #expect(throws: SpeakerEmbeddingBlobCodecError.unsupportedVersion) {
                try SpeakerEmbeddingBlobCodec.decode(slicedWrongVersion, dimensionCount: values.count)
            }
        }

        private func unitVector(index: Int) -> [Float] {
            var values = [Float](repeating: 0, count: SpeakerEmbeddingValidation.dimensionCount)
            values[index] = 1
            return values
        }
    }
#endif
