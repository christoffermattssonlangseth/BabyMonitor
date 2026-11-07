import Foundation

enum SoundLevel {
    /// Converts an RMS amplitude (0…1) to a 0–100 level, mapping −60 dBFS … 0 dBFS.
    static func level(rms: Double) -> Int {
        let db = 20 * log10(max(rms, 1e-6))
        return Int(min(100, max(0, (db + 60) / 60 * 100)).rounded())
    }

    /// Level of 16-bit little-endian PCM samples.
    static func level(pcm16 data: Data) -> Int {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                sum += sample * sample
            }
        }
        return level(rms: (sum / Double(count)).squareRoot())
    }
}

/// Decides when sound has been loud for long enough to alert a parent.
struct NoiseDetector {
    var threshold: Int
    var sustain: TimeInterval
    var cooldown: TimeInterval = 30
    private(set) var aboveSince: Date?
    private var lastAlert: Date?

    init(threshold: Int, sustain: TimeInterval) {
        self.threshold = threshold
        self.sustain = sustain
    }

    /// Feed one level reading. Returns true when an alert should fire.
    mutating func feed(level: Int, at now: Date = Date()) -> Bool {
        guard level >= threshold else {
            aboveSince = nil
            return false
        }
        let start = aboveSince ?? now
        aboveSince = start
        guard now.timeIntervalSince(start) >= sustain else { return false }
        if let last = lastAlert, now.timeIntervalSince(last) < cooldown { return false }
        lastAlert = now
        return true
    }
}

/// Notices when the baby station stops reporting in.
struct ContactWatchdog {
    enum Event: Equatable { case lost, restored }

    var timeout: TimeInterval = 10
    private(set) var lastHeard: Date?
    private(set) var isLost = false

    /// Call for every message from the baby station.
    mutating func heard(at now: Date = Date()) -> Event? {
        lastHeard = now
        if isLost {
            isLost = false
            return .restored
        }
        return nil
    }

    /// Call periodically. Reports `.lost` once per outage. Never fires before
    /// the baby station has been heard from at least once.
    mutating func check(at now: Date = Date()) -> Event? {
        guard let last = lastHeard, !isLost, now.timeIntervalSince(last) > timeout else { return nil }
        isLost = true
        return .lost
    }
}
