// Tests for the platform-independent logic. Run on a Mac:
//   cd ios && swiftc -o /tmp/logic-tests BabyMonitor/Core/Framing.swift BabyMonitor/Core/Detection.swift Tests/main.swift && /tmp/logic-tests
import Foundation

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

// MARK: Framing
do {
    let payload = Data((0..<300).map { UInt8($0 % 256) })
    let encoded = Framing.encode(.video, payload)
    check(encoded.count == 305, "header + payload size")
    let header = Framing.parseHeader(encoded.prefix(5))
    check(header?.type == MessageType.video.rawValue, "type round-trips")
    check(header?.length == 300, "length round-trips")
    check(encoded.suffix(300) == payload, "payload intact")
    check(Framing.parseHeader(Data([1, 0x7f, 0, 0, 0])) == nil, "rejects oversized payload")
    check(Framing.parseHeader(Data([1, 0, 0])) == nil, "rejects short header")
    let empty = Framing.encode(.hello, Data())
    check(Framing.parseHeader(empty)?.length == 0, "empty payload")

    let status = Status(level: 42, camera: true, parents: 2)
    let decoded = try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status))
    check(decoded == status, "status JSON round-trips")
} catch {
    check(false, "unexpected error \(error)")
}

// MARK: Sound level
do {
    check(SoundLevel.level(pcm16: Data()) == 0, "empty is silent")
    check(SoundLevel.level(pcm16: Data(count: 3200)) == 0, "zeros are silent")
    var loud = Data()
    for i in 0..<1600 {
        let v = Int16(i % 2 == 0 ? 32767 : -32767).littleEndian
        withUnsafeBytes(of: v) { loud.append(contentsOf: $0) }
    }
    check(SoundLevel.level(pcm16: loud) == 100, "full scale is 100")
    check(SoundLevel.level(rms: 0.001) == 0, "-60 dB is 0")
    check(SoundLevel.level(rms: 0.0316) == 50, "-30 dB is 50")
}

// MARK: Noise detector
do {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var d = NoiseDetector(threshold: 40, sustain: 2)
    check(!d.feed(level: 80, at: t0), "not yet")
    check(!d.feed(level: 80, at: t0 + 1), "still not")
    check(d.feed(level: 80, at: t0 + 2), "alerts after sustain")
    check(!d.feed(level: 80, at: t0 + 10), "cooldown")
    check(!d.feed(level: 10, at: t0 + 40), "quiet resets")
    check(!d.feed(level: 80, at: t0 + 41), "timer restarted")
    check(d.feed(level: 80, at: t0 + 43), "alerts again after cooldown")
    var instant = NoiseDetector(threshold: 40, sustain: 0)
    check(instant.feed(level: 40, at: t0), "threshold is inclusive, zero sustain")
}

// MARK: Contact watchdog
do {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var w = ContactWatchdog(timeout: 10)
    check(w.check(at: t0 + 100) == nil, "no alarm before first contact")
    check(w.heard(at: t0) == nil, "first contact")
    check(w.check(at: t0 + 9) == nil, "within timeout")
    check(w.check(at: t0 + 11) == .lost, "lost after timeout")
    check(w.check(at: t0 + 30) == nil, "lost reported once")
    check(w.heard(at: t0 + 31) == .restored, "restored")
    check(w.heard(at: t0 + 32) == nil, "restored reported once")
}

if failures == 0 {
    print("All logic tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}
