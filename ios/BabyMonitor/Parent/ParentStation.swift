import Foundation
import Network
import UIKit

/// A parent's phone. Finds the baby station on the Wi-Fi, plays its sound
/// and video, and raises alerts, also while the phone is locked.
final class ParentStation: ObservableObject {
    enum Phase: Equatable {
        case searching
        case connecting(String)
        case live(String)
        case cannotConnect
        case localNetworkDenied
    }

    struct Banner: Equatable {
        let id = UUID()
        let text: String
        let critical: Bool
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    @Published private(set) var phase: Phase = .searching
    @Published private(set) var frame: UIImage?
    @Published private(set) var level = 0
    @Published private(set) var babyCameraOn = true
    @Published private(set) var banner: Banner?
    @Published private(set) var log: [LogEntry] = []

    // Settings, remembered between launches.
    @Published var threshold: Double {
        didSet {
            defaults.set(threshold, forKey: "threshold")
            let value = Int(threshold)
            queue.async { self.detector.threshold = value }
        }
    }
    @Published var sustain: Double {
        didSet {
            defaults.set(sustain, forKey: "sustain")
            let value = sustain
            queue.async { self.detector.sustain = value }
        }
    }
    @Published var volume: Double {
        didSet {
            defaults.set(volume, forKey: "volume")
            player.volume = Float(volume)
        }
    }
    @Published var muted: Bool {
        didSet {
            defaults.set(muted, forKey: "muted")
            player.muted = muted
        }
    }
    @Published var showVideo: Bool {
        didSet {
            defaults.set(showVideo, forKey: "showVideo")
            let value = showVideo
            queue.async {
                self.showVideoSetting = value
                self.sendControl()
            }
        }
    }
    /// Extra quarter turns applied to the picture.
    @Published var rotation: Int {
        didSet { defaults.set(rotation, forKey: "rotation") }
    }

    private let password: String
    private let deviceName: String
    private let defaults = UserDefaults.standard
    private let player = AudioPlayer()
    private var started = false

    // State below is only touched on `queue`.
    private let queue = DispatchQueue(label: "ParentStation.network")
    private var browser: NWBrowser?
    private var results: Set<NWBrowser.Result> = []
    private var connection: FramedConnection?
    private var currentPhase: Phase = .searching
    private var retryDelay: TimeInterval = 1
    private var retryScheduled = false
    private var failedAttempts = 0
    private var detector: NoiseDetector
    private var watchdog = ContactWatchdog(timeout: 10)
    private var watchdogTimer: DispatchSourceTimer?
    private var lastAlarm = Date.distantPast
    private var appActive = true
    private var showVideoSetting: Bool
    private var stopped = false

    init(password: String, deviceName: String) {
        self.password = password
        self.deviceName = deviceName
        let stored = UserDefaults.standard
        let threshold = stored.object(forKey: "threshold") as? Double ?? 35
        let sustain = stored.object(forKey: "sustain") as? Double ?? 2
        let showVideo = stored.object(forKey: "showVideo") as? Bool ?? true
        self.threshold = threshold
        self.sustain = sustain
        self.volume = stored.object(forKey: "volume") as? Double ?? 1
        self.muted = stored.bool(forKey: "muted")
        self.showVideo = showVideo
        self.rotation = stored.integer(forKey: "rotation")
        self.showVideoSetting = showVideo
        self.detector = NoiseDetector(threshold: Int(threshold), sustain: sustain)
    }

    func start() {
        guard !started else { return }
        started = true
        Notifications.requestAuthorization()
        do {
            try player.start()
        } catch {
            addLog("⚠️ Couldn't start audio: \(error.localizedDescription)")
        }
        player.volume = Float(volume)
        player.muted = muted
        queue.async {
            self.startBrowser()
            self.startWatchdog()
        }
    }

    func stop() {
        player.stop()
        queue.async {
            self.stopped = true
            self.watchdogTimer?.cancel()
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    /// Video is paused while the app isn't on screen, to save battery. Sound keeps playing.
    func setAppActive(_ active: Bool) {
        queue.async {
            self.appActive = active
            self.sendControl()
        }
    }

    func dismissBanner() {
        banner = nil
    }

    // MARK: - Finding and connecting (on `queue`)

    private func startBrowser() {
        guard !stopped else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: BonjourService.type, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if self.currentPhase == .localNetworkDenied { self.setPhase(.searching) }
            case .waiting(let error):
                self.handleBrowserError(error)
            case .failed(let error):
                self.handleBrowserError(error)
                self.browser?.cancel()
                self.browser = nil
                self.queue.asyncAfter(deadline: .now() + 2) { self.startBrowser() }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.results = results
            self.connectIfNeeded()
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleBrowserError(_ error: NWError) {
        // kDNSServiceErr_PolicyDenied: the user hasn't allowed Local Network access.
        if case .dns(let code) = error, code == -65570 {
            setPhase(.localNetworkDenied)
        }
    }

    private func connectIfNeeded() {
        guard !stopped, connection == nil, !retryScheduled else { return }
        guard let result = results.first, case let .service(name, _, _, _) = result.endpoint else {
            if currentPhase != .localNetworkDenied { setPhase(.searching) }
            return
        }
        connect(to: result.endpoint, name: name)
    }

    private func connect(to endpoint: NWEndpoint, name: String) {
        if currentPhase != .cannotConnect { setPhase(.connecting(name)) }
        let connection = FramedConnection(NWConnection(to: endpoint, using: .babyMonitor(password: password)), queue: queue)
        self.connection = connection

        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.retryDelay = 1
            self.failedAttempts = 0
            connection.send(.hello, json: Hello(name: self.deviceName))
            self.sendControl()
            self.setPhase(.live(name))
            self.addLog("👶 Connected to \(name)")
        }
        connection.onMessage = { [weak self] type, payload in
            self?.handle(type: type, payload: payload)
        }
        connection.onClose = { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            self.connection = nil
            if case .live = self.currentPhase {
                self.addLog("Disconnected from \(name)")
                self.setPhase(.searching)
            } else {
                // Never got through. A wrong password fails the TLS handshake;
                // repeated failures while the station is visible mean the same.
                self.failedAttempts += 1
                if error?.isTLSFailure == true || self.failedAttempts >= 3 {
                    self.setPhase(.cannotConnect)
                }
            }
            self.scheduleRetry()
        }
        connection.start(timeout: 8)
    }

    private func scheduleRetry() {
        guard !stopped, !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.connectIfNeeded()
        }
    }

    private func sendControl() {
        guard let connection, connection.isReady else { return }
        connection.send(.control, json: Control(wantsVideo: appActive && showVideoSetting))
    }

    private func setPhase(_ phase: Phase) {
        currentPhase = phase
        DispatchQueue.main.async { self.phase = phase }
    }

    // MARK: - Incoming data (on `queue`)

    private func handle(type: UInt8, payload: Data) {
        let now = Date()
        if watchdog.heard(at: now) == .restored {
            contactRestored()
        }
        guard let kind = MessageType(rawValue: type) else { return }
        switch kind {
        case .audio:
            player.enqueue(pcm16: payload)
        case .video:
            guard appActive, showVideoSetting, let image = UIImage(data: payload) else { return }
            DispatchQueue.main.async { self.frame = image }
        case .status:
            guard let status = try? JSONDecoder().decode(Status.self, from: payload) else { return }
            if detector.feed(level: status.level, at: now) {
                noiseAlert()
            }
            DispatchQueue.main.async {
                self.level = status.level
                self.babyCameraOn = status.camera
            }
        default:
            break
        }
    }

    // MARK: - Alerts (on `queue`)

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkContact() }
        timer.resume()
        watchdogTimer = timer
    }

    private func checkContact() {
        let now = Date()
        if watchdog.check(at: now) == .lost {
            contactLost()
            connection?.cancel() // reconnect from scratch
        } else if watchdog.isLost, now.timeIntervalSince(lastAlarm) > 60 {
            // Keep reminding every minute until the baby station is back.
            lastAlarm = now
            player.playAlarm(.lostContact)
        }
    }

    private func noiseAlert() {
        player.playAlarm(.noise)
        Notifications.post(title: "🔊 Sound in the nursery",
                           body: "Noise for \(Int(detector.sustain))+ seconds.",
                           urgent: true)
        showBanner("🔊 Sound detected in the nursery", critical: false)
        addLog("🔊 Sound detected")
    }

    private func contactLost() {
        lastAlarm = Date()
        player.playAlarm(.lostContact)
        Notifications.post(title: "⚠️ Lost contact with the baby station",
                           body: "Check the nursery phone: battery, Wi-Fi, or the app was closed.",
                           urgent: true)
        showBanner("⚠️ Lost contact with the baby station", critical: true)
        addLog("⚠️ Lost contact")
        DispatchQueue.main.async { self.level = 0 }
    }

    private func contactRestored() {
        Notifications.post(title: "✅ Baby station is back", body: "Contact restored.", urgent: false)
        DispatchQueue.main.async {
            if self.banner?.critical == true { self.banner = nil }
        }
        addLog("✅ Contact restored")
    }

    private func showBanner(_ text: String, critical: Bool) {
        DispatchQueue.main.async {
            let banner = Banner(text: text, critical: critical)
            self.banner = banner
            guard !critical else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if self.banner == banner { self.banner = nil }
            }
        }
    }

    private func addLog(_ text: String) {
        DispatchQueue.main.async {
            self.log.insert(LogEntry(text: text), at: 0)
            if self.log.count > 200 { self.log.removeLast() }
        }
    }
}
