import Foundation

/// Low-bandwidth audio for cellular: 8 kHz G.711 µ-law, 64 kbit/s instead of
/// 256 kbit/s for 16 kHz 16-bit PCM. Plenty for hearing a baby, and simple
/// enough to never fail.
enum MuLaw {
    private static let bias = 0x84
    private static let clip = 32635

    static func encode(_ sample: Int16) -> UInt8 {
        var magnitude = Int(sample)
        let sign = magnitude < 0 ? 0x80 : 0
        if magnitude < 0 { magnitude = -magnitude }
        magnitude = min(magnitude, clip) + bias
        var exponent = 7
        var mask = 0x4000
        while exponent > 0 && (magnitude & mask) == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (magnitude >> (exponent + 3)) & 0x0F
        return UInt8(~(sign | (exponent << 4) | mantissa) & 0xFF)
    }

    static func decode(_ byte: UInt8) -> Int16 {
        let value = Int(~byte)
        let exponent = (value >> 4) & 0x07
        let mantissa = value & 0x0F
        let magnitude = (((mantissa << 3) + bias) << exponent) - bias
        return Int16(value & 0x80 != 0 ? -magnitude : magnitude)
    }

    /// 16 kHz 16-bit little-endian PCM → 8 kHz µ-law (averages sample pairs).
    static func encode16kPCM(_ pcm: Data) -> Data {
        let pairs = pcm.count / 4
        var out = [UInt8](repeating: 0, count: pairs)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<pairs {
                let a = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self)))
                let b = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self)))
                out[i] = encode(Int16((a + b) / 2))
            }
        }
        return Data(out)
    }

    /// 8 kHz µ-law → 16 kHz 16-bit little-endian PCM (linear interpolation).
    static func decodeTo16kPCM(_ bytes: Data) -> Data {
        let samples = bytes.map { Int(decode($0)) }
        var out = Data(capacity: samples.count * 4)
        for (i, sample) in samples.enumerated() {
            let next = i + 1 < samples.count ? samples[i + 1] : sample
            for value in [sample, (sample + next) / 2] {
                let le = Int16(value).littleEndian
                withUnsafeBytes(of: le) { out.append(contentsOf: $0) }
            }
        }
        return out
    }
}
