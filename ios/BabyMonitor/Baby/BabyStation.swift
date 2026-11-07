import AVFoundation
import Foundation
import Network

/// The device in the nursery. Announces itself on the Wi-Fi with Bonjour,
/// accepts parent connections, and streams sound, video and status to them.
final class BabyStation: ObservableObject {
    @Published private(set) var parentNames: [String] = []
    @Published private(set) var level = 0
    @Published private(set) var isOnline = false
    @Published private(set) var problem: String?
    @Published private(set) var usingFrontCamera = false
    /// Address parents can use away from home, if Tailscale is running on this phone.
    @Published private(set) var remoteAddress: String?
    @Published var cameraOn = true {
        didSet {
            let on = cameraOn
            video.setRunning(on)
            queue.async {
                self.cameraOnForNetwork = on
                self.updateWantsFrames()
            }
        }
    }

    let video = VideoCapture()

    private let audio = AudioCapture()
    private let password: String
    private let name: String
    private var started = false

    // State below is only touched on `queue`.
    private let queue = DispatchQueue(label: "BabyStation.network")
    private var listener: NWListener?
    private var parents: [ObjectIdentifier: ParentLink] = [:]
    private var latestLevel = 0
    private var cameraOnForNetwork = true
    private var statusTimer: DispatchSourceTimer?
    private var stopped = false

    private final class ParentLink {
        let connection: FramedConnection
        var name = "Parent"
        var greeted = false
        var wantsVideo = true
        var lowData = false
        var lastVideoSent = Date.distantPast
        init(_ connection: FramedConnection) { self.connection = connection }
    }

    init(password: String, name: String) {
        self.password = password
        self.name = name
    }

    func start() {
        guard !started else { return }
        started = true
        AVCaptureDevice.requestAccess(for: .video) { videoAllowed in
            AVAudioApplication.requestRecordPermission { audioAllowed in
                DispatchQueue.main.async {
                    self.startCapture(videoAllowed: videoAllowed, audioAllowed: audioAllowed)
                }
            }
        }
    }

    func stop() {
        audio.stop()
        video.stop()
        queue.async {
            self.stopped = true
            self.statusTimer?.cancel()
            self.listener?.cancel()
            self.listener = nil
            for link in self.parents.values { link.connection.cancel() }
            self.parents.removeAll()
        }
    }

    /// Tailscale may connect after the app starts, so the view calls this regularly.
    func refreshRemoteAddress() {
        let address = tailscaleIPv4Address()
        if address != remoteAddress { remoteAddress = address }
    }

    func switchCamera() {
        usingFrontCamera.toggle()
        video.configure(frontCamera: usingFrontCamera, run: cameraOn) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.problem = error.localizedDescription }
        }
    }

    // MARK: - Capture

    private func startCapture(videoAllowed: Bool, audioAllowed: Bool) {
        var problems: [String] = []

        if audioAllowed {
            audio.onChunk = { [weak self] pcm, level in
                self?.queue.async { self?.broadcastAudio(pcm, level: level) }
            }
            do {
                try audio.start()
            } catch {
                problems.append("Microphone problem: \(error.localizedDescription)")
            }
        } else {
            problems.append("Microphone access is off. Turn it on in Settings → Baby Monitor.")
        }

        if !videoAllowed {
            problems.append("Camera access is off, so parents get sound only. Turn it on in Settings → Baby Monitor.")
            cameraOn = false
        }
        problem = problems.isEmpty ? nil : problems.joined(separator: "\n")

        if videoAllowed {
            video.onFrame = { [weak self] jpeg in
                self?.queue.async { self?.broadcastVideo(jpeg) }
            }
            video.configure(frontCamera: usingFrontCamera, run: cameraOn) { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async { self?.problem = "Camera problem: \(error.localizedDescription)" }
            }
        }
        queue.async {
            self.startListener()
            self.startStatusTimer()
        }
    }

    // MARK: - Network (on `queue`)

    private func startListener() {
        guard !stopped else { return }
        do {
            let port = NWEndpoint.Port(rawValue: BonjourService.port)!
            let listener = try NWListener(using: .babyMonitor(password: password), on: port)
            listener.service = NWListener.Service(name: name, type: BonjourService.type)
            listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            retryListener()
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let address = tailscaleIPv4Address()
            DispatchQueue.main.async {
                self.isOnline = true
                self.remoteAddress = address
            }
        case .failed:
            DispatchQueue.main.async { self.isOnline = false }
            listener?.cancel()
            listener = nil
            retryListener()
        case .waiting:
            DispatchQueue.main.async { self.isOnline = false }
        default:
            break
        }
    }

    private func retryListener() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startListener() }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = FramedConnection(nwConnection, queue: queue)
        let link = ParentLink(connection)
        let id = ObjectIdentifier(link)
        parents[id] = link

        connection.onMessage = { [weak self, weak link] type, payload in
            guard let self, let link, let kind = MessageType(rawValue: type) else { return }
            switch kind {
            case .hello:
                guard let hello = try? JSONDecoder().decode(Hello.self, from: payload) else { return }
                link.name = String(hello.name.prefix(40))
                link.greeted = true
                self.publishParents()
            case .control:
                guard let control = try? JSONDecoder().decode(Control.self, from: payload) else { return }
                link.wantsVideo = control.wantsVideo
                link.lowData = control.lowData ?? false
                self.updateWantsFrames()
            default:
                break
            }
        }
        connection.onClose = { [weak self] _ in
            guard let self else { return }
            self.parents[id] = nil
            self.publishParents()
        }
        // A wrong password fails the TLS handshake; don't keep half-open connections around.
        connection.start(timeout: 10)
    }

    private var readyParents: [ParentLink] {
        parents.values.filter { $0.greeted && $0.connection.isReady }
    }

    private func publishParents() {
        let names = readyParents.map(\.name).sorted()
        updateWantsFrames()
        DispatchQueue.main.async { self.parentNames = names }
    }

    private func updateWantsFrames() {
        video.wantsFrames = cameraOnForNetwork && readyParents.contains { $0.wantsVideo }
    }

    private func broadcastAudio(_ pcm: Data, level: Int) {
        latestLevel = level
        var compressed: Data?
        // Skip a parent that has fallen more than ~3 s behind (e.g. weak signal).
        for link in readyParents where link.connection.pendingSends < 30 {
            if link.lowData {
                if compressed == nil { compressed = MuLaw.encode16kPCM(pcm) }
                link.connection.send(.audioMuLaw, compressed!)
            } else {
                link.connection.send(.audio, pcm)
            }
        }
        DispatchQueue.main.async { self.level = level }
    }

    private func broadcastVideo(_ jpeg: Data) {
        let now = Date()
        // Drop frames for slow connections so sound never waits behind video,
        // and send only 1 frame per second to parents on cellular.
        for link in readyParents where link.wantsVideo && link.connection.pendingSends < 3 {
            if link.lowData, now.timeIntervalSince(link.lastVideoSent) < 1 { continue }
            link.lastVideoSent = now
            link.connection.send(.video, jpeg)
        }
    }

    private func startStatusTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let ready = self.readyParents
            let status = Status(level: self.latestLevel, camera: self.cameraOnForNetwork, parents: ready.count)
            guard let data = try? JSONEncoder().encode(status) else { return }
            for link in ready {
                link.connection.send(.status, data)
            }
        }
        timer.resume()
        statusTimer = timer
    }
}
