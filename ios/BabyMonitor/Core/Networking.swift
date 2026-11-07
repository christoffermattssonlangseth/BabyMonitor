import CryptoKit
import Foundation
import Network

enum BonjourService {
    /// Must match NSBonjourServices in Info.plist.
    static let type = "_babymonitor._tcp"
}

extension NWParameters {
    /// TCP + TLS with a key derived from the family password (TLS-PSK).
    /// Only devices that know the password can connect, and everything,
    /// including audio and video, is encrypted on the Wi-Fi.
    static func babyMonitor(password: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Notice a vanished peer (battery died, out of Wi-Fi) within seconds.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tlsOptions(password: password), tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func tlsOptions(password: String) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(password.utf8))
        let psk = Data(HMAC<SHA256>.authenticationCode(for: Data("BabyMonitor PSK v1".utf8), using: key))
        let identity = Data("BabyMonitor".utf8)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        let options = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(options, pskData as __DispatchData, identityData as __DispatchData)
        // TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8); PSK cipher suites need TLS 1.2.
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00A8)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        return tls
    }
}

extension NWError {
    var isTLSFailure: Bool {
        if case .tls = self { return true }
        return false
    }
}

/// Wraps an NWConnection and sends / receives framed messages.
/// All callbacks run on the queue passed to `init`; call methods only from that queue.
final class FramedConnection {
    var onReady: (() -> Void)?
    var onMessage: ((UInt8, Data) -> Void)?
    /// Called once when the connection ends, with the error if it failed.
    var onClose: ((NWError?) -> Void)?

    private(set) var isReady = false
    /// Messages handed to the network but not yet sent. Used to drop video
    /// frames instead of building up delay on a slow connection.
    private(set) var pendingSends = 0

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// - Parameter timeout: give up if the connection isn't ready by then.
    func start(timeout: TimeInterval? = nil) {
        connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
        connection.start(queue: queue)
        receiveHeader()
        if let timeout {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !self.isReady else { return }
                self.close(error: nil)
            }
        }
    }

    func send(_ type: MessageType, _ payload: Data) {
        guard !closed else { return }
        pendingSends += 1
        connection.send(content: Framing.encode(type, payload), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingSends -= 1
            if let error { self.close(error: error) }
        })
    }

    func send<T: Encodable>(_ type: MessageType, json value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        send(type, data)
    }

    func cancel() {
        close(error: nil)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            onReady?()
        case .waiting(let error), .failed(let error):
            // `.waiting` would retry by itself; we prefer to fail and let the
            // station decide when and where to reconnect.
            close(error: error)
        case .cancelled:
            close(error: nil)
        default:
            break
        }
    }

    private func close(error: NWError?) {
        guard !closed else { return }
        closed = true
        isReady = false
        connection.stateUpdateHandler = nil
        connection.cancel()
        let onClose = self.onClose
        self.onClose = nil
        onReady = nil
        onMessage = nil
        onClose?(error)
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: Framing.headerSize, maximumLength: Framing.headerSize) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let error { self.close(error: error); return }
            guard let data, let header = Framing.parseHeader(data) else { self.close(error: nil); return }
            if header.length == 0 {
                self.onMessage?(header.type, Data())
                self.receiveHeader()
            } else {
                self.receiveBody(type: header.type, length: header.length)
            }
        }
    }

    private func receiveBody(type: UInt8, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let error { self.close(error: error); return }
            guard let data, data.count == length else { self.close(error: nil); return }
            self.onMessage?(type, data)
            self.receiveHeader()
        }
    }
}
