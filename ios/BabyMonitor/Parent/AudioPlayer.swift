import AVFoundation

/// Plays the baby station's sound plus alert tones.
///
/// The engine runs all night, even when nothing arrives. That keeps the app
/// alive in the background (background audio mode), so it can keep listening
/// and raise alerts while the phone is locked.
final class AudioPlayer {
    enum Alarm { case noise, lostContact }

    var volume: Float = 1 { didSet { applyVolume() } }
    var muted = false { didSet { applyVolume() } }

    private let engine = AVAudioEngine()
    private let stream = AVAudioPlayerNode()
    private let alarm = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    // Recursive in case AVFoundation ever calls a completion handler synchronously.
    private let lock = NSRecursiveLock()
    private var scheduled = 0
    private var prebuffer: [AVAudioPCMBuffer] = []
    private var observers: [NSObjectProtocol] = []

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // .playback keeps playing when the phone is locked or the silent switch is on.
        try session.setCategory(.playback, mode: .default)
        engine.attach(stream)
        engine.attach(alarm)
        engine.connect(stream, to: engine.mainMixerNode, format: format)
        engine.connect(alarm, to: engine.mainMixerNode, format: format)
        try startEngine()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? self?.startEngine()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            try? self?.startEngine()
        })
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() throws {
        try AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            lock.withLock {
                scheduled = 0
                prebuffer.removeAll()
            }
            engine.prepare()
            try engine.start()
        }
        stream.play()
        alarm.play()
        applyVolume()
    }

    private func applyVolume() {
        stream.volume = muted ? 0 : volume
    }

    /// Queue 16 kHz mono 16-bit PCM from the baby station. Safe to call from any thread.
    func enqueue(pcm16 data: Data) {
        let frames = data.count / 2
        guard frames > 0, engine.isRunning,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                channel[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }

        lock.lock()
        defer { lock.unlock() }
        if scheduled == 0 {
            // Ran dry (start, or Wi-Fi hiccup): gather 300 ms first so playback doesn't stutter.
            prebuffer.append(buffer)
            guard prebuffer.count >= 3 else { return }
            for pending in prebuffer { schedule(pending) }
            prebuffer.removeAll()
        } else if scheduled <= 10 {
            schedule(buffer)
        }
        // More than ~1 s queued: drop this chunk to stay close to real time.
    }

    /// Must be called with `lock` held.
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        scheduled += 1
        stream.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.scheduled = max(0, self.scheduled - 1) }
        }
    }

    /// Plays an alert tone. Plays even when the phone is locked or muted
    /// with the silent switch, but not when the live sound is muted in the app.
    func playAlarm(_ kind: Alarm) {
        if !engine.isRunning { try? startEngine() }
        let notes: [Float] = kind == .noise ? [660, 880] : [880, 660, 880, 660, 880, 660]
        let sampleRate = Float(format.sampleRate)
        let framesPerNote = Int(sampleRate * 0.25)
        let total = framesPerNote * notes.count
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(total)
        for (n, frequency) in notes.enumerated() {
            for i in 0..<framesPerNote {
                let t = Float(i) / sampleRate
                // Short fade in/out avoids clicks.
                let envelope = min(1, Float(i) / 200) * min(1, Float(framesPerNote - i) / 800)
                channel[n * framesPerNote + i] = 0.6 * envelope * sin(2 * .pi * frequency * t)
            }
        }
        alarm.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }
}
