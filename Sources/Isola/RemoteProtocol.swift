import Foundation
import Network
import Security
import CommonCrypto
import Darwin

struct RemoteInput: Codable {
    var kind: String
    var x: Double = 0
    var y: Double = 0
    var code: UInt16 = 0
    var flags: UInt64 = 0
    var text: String = ""
    var deltaX: Double = 0
    var deltaY: Double = 0
    var clicks: Int = 1
    var epoch: UInt64 = 0
    var phase: UInt64 = 0
    var momentum: UInt64 = 0
    var precise: Bool = true
}
struct RemoteVideo: Codable {
    var bytes: Data
    var sps: Data
    var pps: Data
    var width: Int
    var height: Int
    var keyframe: Bool
    var codec: String = "h264"
    var vps: Data = Data()
    var epoch: UInt64 = 0
    var sequence: UInt64 = 0
    var encodeMilliseconds: Double = 0
}
struct RemotePacket: Codable {
    var kind: String
    var version: Int? = nil
    var name: String? = nil
    var input: RemoteInput? = nil
    var video: RemoteVideo? = nil
    var clipboard: ClipboardMessage? = nil
    var clipboardEnabled: Bool? = nil
    var syncKeyboard: Bool? = nil
    var channel: String? = nil
    var token: String? = nil
    var viewport: RemoteViewport? = nil
    var sequence: UInt64? = nil
    var timestamp: Double? = nil
    var codecs: [String]? = nil
    var cursor: RemoteCursor? = nil
}

// A second socket is part of a controller only after proving possession of its
// random session token. Merely knowing the LAN/password key cannot attach a
// video/clipboard socket to somebody else's active controller.
struct RemoteChannelBinding {
    private(set) var token: String?
    private(set) var channels: [UUID: String] = [:]
    mutating func begin(_ id: UUID) -> String? {
        guard channels.isEmpty else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let value = Data(bytes).base64EncodedString()
        token = value; channels[id] = "control"; return value
    }
    mutating func join(_ id: UUID, channel: String, token: String?) -> Bool {
        guard let expected = self.token, token == expected,
              ["video", "clipboard"].contains(channel), channels[id] == nil,
              !channels.values.contains(channel) else { return false }
        channels[id] = channel; return true
    }
    mutating func remove(_ id: UUID) -> String? { channels.removeValue(forKey: id) }
    mutating func reset() { channels.removeAll(); token = nil }
}

enum RemoteSecurity {
    static let version = 2
    static let serviceType = "_isola-vm._tcp"
    // TLS 1.2 ECDHE-PSK also encrypts open LAN sessions. The public open-mode
    // key grants no identity/authentication; anyone on the subnet may connect.
    static func parameters(password: String?) throws -> NWParameters {
        let password = password ?? "org.isola.open-lan.v1"
        guard !password.isEmpty, password.utf8.count <= 1024 else { throw failure(L("Введи пароль (до 1024 байт).", "Enter a password (up to 1024 bytes).")) }
        let salt = Array("org.isola.remote.password.v1".utf8)
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = password.withCString { value in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), value, password.utf8.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 120_000, &bytes, bytes.count)
        }
        guard result == kCCSuccess else { throw failure("Password key derivation failed.") }
        let key = Data(bytes)
        let tls = NWProtocolTLS.Options()
        let identity = Data("org.isola.remote.v1".utf8)
        key.withUnsafeBytes { bytes in identity.withUnsafeBytes { id in
            sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, DispatchData(bytes: bytes) as __DispatchData, DispatchData(bytes: id) as __DispatchData)
        } }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // PSK proves possession of the password; no certificate identity is used.
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0xCCAC)!)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "isola-remote/1")
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        return parameters
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "Isola Remote", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func savedPassword(account: String) -> String? {
        var query = keychainQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func savePassword(_ code: String, account: String) throws {
        var update: [String: Any] = [kSecValueData as String: Data(code.utf8)]
        let query = keychainQuery(account)
        var result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if result == errSecItemNotFound {
            update.merge(query) { a, _ in a }
            update[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(update as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw failure("Keychain: \(result)") }
    }
    private static func keychainQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.isola.remote", kSecAttrAccount as String: account]
    }
}

// Bonjour discovery is local, and accepted peers must also be on a directly
// connected subnet. Reject external source addresses even if a port is forwarded.
enum RemoteLAN {
    static func allows(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        var peer: [UInt8]
        switch host {
        case .ipv4(let address): peer = Array(address.rawValue)
        case .ipv6(let address):
            peer = Array(address.rawValue)
            if peer.prefix(12) == [0,0,0,0,0,0,0,0,0,0,255,255] { peer = Array(peer.suffix(4)) }
        default: return false
        }
        if peer == [127,0,0,1] || peer == Array(repeating: UInt8(0), count: 15) + [1] { return true }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return false }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("bond"),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = item.pointee.ifa_addr, let mask = item.pointee.ifa_netmask else { continue }
            let local = bytes(address), subnet = bytes(mask)
            if peer.count == local.count, peer.count == subnet.count,
               zip(zip(peer, local), subnet).allSatisfy({ ($0.0.0 & $0.1) == ($0.0.1 & $0.1) }) { return true }
        }
        return false
    }
    private static func bytes(_ address: UnsafePointer<sockaddr>) -> [UInt8] {
        if address.pointee.sa_family == AF_INET {
            var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            return withUnsafeBytes(of: &value) { Array($0) }
        }
        if address.pointee.sa_family == AF_INET6 {
            var value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            return withUnsafeBytes(of: &value) { Array($0) }
        }
        return []
    }
}

// Each channel owns its queue and socket: control never sits behind video/files.
// The video encoder additionally limits frames awaiting a *decoder* acknowledgement.
final class RemoteLink: @unchecked Sendable {
    static let limit = 90 * 1024 * 1024
    let connection: NWConnection
    private let queue = DispatchQueue(label: "org.isola.remote.link", qos: .userInteractive)
    private var closed = false
    private var ready = false
    private var pendingBytes = 0
    private var pendingCount = 0
    private var receiveLimit: Int
    var onReady: (() -> Void)?
    var onPacket: ((RemotePacket, @escaping () -> Void) -> Void)?
    var onClose: ((String?) -> Void)?
    init(_ connection: NWConnection, receiveLimit: Int = RemoteLink.limit) { self.connection = connection; self.receiveLimit = receiveLimit }
    func setReceiveLimit(_ limit: Int) { queue.async { self.receiveLimit = limit } }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.ready = true; self.onReady?(); self.readHeader()
            case .failed(let error): self.finish(error.localizedDescription)
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.ready else { return }
            self.finish(L("Не удалось подключиться. Проверь пароль и локальную сеть.", "Connection failed. Check the password and local network."))
        }
    }
    func stop() { queue.async { [self] in finish(nil) } }
    private func finish(_ error: String?) {
        guard !closed else { return }; closed = true
        connection.stateUpdateHandler = nil; connection.cancel()
        onClose?(error)
        onReady = nil; onPacket = nil; onClose = nil
    }
    func send(_ packet: RemotePacket, completion: @escaping () -> Void = {}) {
        queue.async { [self] in
            guard !closed, ready else { completion(); return }
            do {
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let payload = try encoder.encode(packet)
                guard payload.count <= Self.limit, pendingCount < 128, pendingBytes + payload.count <= Self.limit + 16 * 1024 * 1024 else {
                    completion(); finish("Remote connection is too slow."); return
                }
                var length = UInt32(payload.count).bigEndian
                var data = withUnsafeBytes(of: &length) { Data($0) }; data.append(payload)
                pendingCount += 1; pendingBytes += payload.count
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { completion(); return }
                    self.pendingCount -= 1; self.pendingBytes -= payload.count
                    completion()
                    if let error { self.finish(error.localizedDescription) }
                })
            } catch { completion(); finish(error.localizedDescription) }
        }
    }
    private func readHeader() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == 4 else { self.finish(error?.localizedDescription); return }
            let count = data.reduce(0) { ($0 << 8) | Int($1) }
            guard count > 0, count <= self.receiveLimit else { self.finish("Invalid remote frame."); return }
            self.readPayload(count)
        }
    }
    private func readPayload(_ count: Int) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == count,
                  let packet = try? PropertyListDecoder().decode(RemotePacket.self, from: data) else { self.finish("Invalid remote packet."); return }
            if let receive = self.onPacket {
                receive(packet) { [weak self] in self?.queue.async { [weak self] in self?.readHeader() } }
            } else { self.readHeader() }
        }
    }
}
