import Foundation

/// Wire protocol between the baby station and parent stations.
///
/// Every message is a 5-byte header followed by the payload:
///   [type: UInt8][payload length: UInt32 big-endian][payload]
enum MessageType: UInt8 {
    /// parent → baby, JSON `Hello`
    case hello = 1
    /// baby → parent, 100 ms of 16 kHz mono 16-bit little-endian PCM
    case audio = 2
    /// baby → parent, one JPEG frame
    case video = 3
    /// baby → parent, JSON `Status`, 4 times a second. Doubles as the heartbeat.
    case status = 4
    /// parent → baby, JSON `Control`
    case control = 5
    /// baby → parent, 100 ms of 8 kHz G.711 µ-law (data saver, for cellular)
    case audioMuLaw = 6
}

struct Hello: Codable, Equatable {
    var name: String
    var version: Int = 1
}

struct Status: Codable, Equatable {
    /// Sound level 0–100 (−60 dBFS … 0 dBFS).
    var level: Int
    var camera: Bool
    var parents: Int
}

struct Control: Codable, Equatable {
    /// False while the parent app is in the background or video is hidden, to save battery.
    var wantsVideo: Bool
    /// True when the parent isn't on Wi-Fi: compressed sound, 1 video frame per second.
    var lowData: Bool?
}

enum Framing {
    static let headerSize = 5
    static let maxPayload = 4 * 1024 * 1024

    static func encode(_ type: MessageType, _ payload: Data) -> Data {
        var data = Data(capacity: headerSize + payload.count)
        data.append(type.rawValue)
        let length = UInt32(payload.count)
        data.append(UInt8(truncatingIfNeeded: length >> 24))
        data.append(UInt8(truncatingIfNeeded: length >> 16))
        data.append(UInt8(truncatingIfNeeded: length >> 8))
        data.append(UInt8(truncatingIfNeeded: length))
        data.append(payload)
        return data
    }

    /// Parses a header. Returns nil if it is malformed or announces an oversized payload.
    /// The type is returned raw so newer message types can be ignored by older apps.
    static func parseHeader(_ header: Data) -> (type: UInt8, length: Int)? {
        guard header.count == headerSize else { return nil }
        let b = [UInt8](header)
        let length = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
        guard length <= maxPayload else { return nil }
        return (b[0], length)
    }
}
