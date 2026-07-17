import Foundation

extension UUID {
    /// UUID v7 を生成する（RFC 9562 準拠）。
    ///
    /// レイアウト:
    /// - 48 bit: Unix タイムスタンプ (ミリ秒)
    /// - 4 bit: バージョン (0111 = 7)
    /// - 12 bit: ランダム
    /// - 2 bit: バリアント (10)
    /// - 62 bit: ランダム
    static func v7() -> UUID {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)

        var bytes = (
            UInt8(truncatingIfNeeded: ms >> 40),
            UInt8(truncatingIfNeeded: ms >> 32),
            UInt8(truncatingIfNeeded: ms >> 24),
            UInt8(truncatingIfNeeded: ms >> 16),
            UInt8(truncatingIfNeeded: ms >> 8),
            UInt8(truncatingIfNeeded: ms),
            UInt8(0), UInt8(0), // version + rand_a
            UInt8(0), UInt8(0), // variant + rand_b
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)
        )

        // ランダムビットを埋める (bytes 6..15)
        withUnsafeMutableBytes(of: &bytes) { buf in
            // bytes 6〜15 にランダム値を書き込み
            for i in 6 ..< 16 {
                buf[i] = UInt8.random(in: 0 ... 255)
            }
        }

        // version: 上位4ビットを 0111 に設定 (byte 6)
        bytes.6 = (bytes.6 & 0x0F) | 0x70

        // variant: 上位2ビットを 10 に設定 (byte 8)
        bytes.8 = (bytes.8 & 0x3F) | 0x80

        return UUID(uuid: bytes)
    }
}
