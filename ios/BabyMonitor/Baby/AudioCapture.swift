import AVFoundation

enum CaptureError: LocalizedError {
    case noMicrophone
    case noCamera

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone available."
        case .noCamera: return "No camera available."
        }
    }
}

/// Records the microphone and delivers 100 ms chunks of 16 kHz mono 16-bit PCM.
/// Keeps running while the screen is locked (background audio mode).
final class AudioCapture {
    /// Called on an audio thread with a PCM chunk and its sound level (0–100).
    var onChunk: ((Data, Int) -> Void)?

    static let chunkBytes = 3200 // 1600 samples = 100 ms at 16 kHz

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var observers: [NSObjectProtocol] = []

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement turns off voice processing, so quiet sounds such as
        // whimpering aren't filtered out as "noise".
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        try startEngine()

        let center = NotificationCenter.default
        // Restart after a phone call or Siri, or when the audio route changes.
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() throws {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noMicrophone }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        pending.removeAll()
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        try AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        try engine.start()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData else { return }

        pending.append(Data(bytes: samples[0], count: Int(converted.frameLength) * 2))
        while pending.count >= Self.chunkBytes {
            let chunk = Data(pending.prefix(Self.chunkBytes))
            pending.removeFirst(Self.chunkBytes)
            onChunk?(chunk, SoundLevel.level(pcm16: chunk))
        }
    }
}
