import Foundation
import Virtualization
import Darwin

struct ProxySettings: Codable {
    var Host: String
    var Port: Int
    var Username: String
    var Password: String
    var GuestMAC: String? = nil
    var DirectRules: [String] = []
}

// Mutable lifecycle state is used on the main thread; termination only enqueues there.
final class NetworkBridge: @unchecked Sendable {
    let process = Process()
    var handle: FileHandle?
    private let directory: URL
    private var lifetimePipe: Pipe?
    var onExit: (() -> Void)?
    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("isola-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/isola-network") }
    func start(_ settings: ProxySettings) async throws -> VZFileHandleNetworkDeviceAttachment {
        let server = directory.appendingPathComponent("gw.sock").path
        let client = directory.appendingPathComponent("vm.sock").path
        let input = Pipe()
        lifetimePipe = input
        process.executableURL = Self.executable
        process.arguments = ["--socket", server, "--peer", client, "--stats", directory.appendingPathComponent("network-stats.json").path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.onExit?() } }
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(settings) + Data([10]))
        var ready = false
        for _ in 0..<100 {
            guard process.isRunning else { throw AppError.message(L("Сетевой шлюз отклонил настройки SOCKS. Нужен IP-адрес, порт и корректные поля авторизации.", "The network gateway rejected the SOCKS settings. Check the IP address, port and credentials.")) }
            if FileManager.default.fileExists(atPath: server) { ready = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard ready else { throw AppError.message(L("Сетевой шлюз не запустился.", "The network gateway did not start.")) }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw AppError.message(L("Не удалось создать сетевой адаптер.", "Could not create the network adapter.")) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // VZ requires receive capacity >= 2x send capacity; Apple recommends 4x.
        var sendSize: Int32 = 256 * 1024, receiveSize: Int32 = 1024 * 1024
        guard setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendSize, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveSize, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw AppError.message(L("Не удалось настроить буферы сетевого адаптера: \(errno)", "Could not configure network adapter buffers: \(errno)"))
        }
        try Self.address(client) { Darwin.bind(fd, $0, $1) }
        try Self.address(server) { Darwin.connect(fd, $0, $1) }
        handle = file
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: file)
        attachment.maximumTransmissionUnit = 1500
        return attachment
    }
    private static func address(_ path: String, action: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw AppError.message(L("Слишком длинный путь сетевого сокета.", "Network socket path is too long.")) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in bytes.withUnsafeBytes { raw.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { action($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw AppError.message(L("Ошибка локального сетевого сокета: \(errno)", "Local network socket error: \(errno)")) }
    }
    func stop() {
        onExit = nil
        try? lifetimePipe?.fileHandleForWriting.close(); lifetimePipe = nil
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? handle?.close(); handle = nil
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { stop() }
    static func check(_ settings: ProxySettings) async throws {
        try await Task.detached {
            let p = Process(), input = Pipe(), errors = Pipe()
            p.executableURL = executable; p.arguments = ["--check"]
            p.standardInput = input; p.standardOutput = FileHandle.nullDevice; p.standardError = errors
            try p.run(); try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(settings)); try input.fileHandleForWriting.close()
            p.waitUntilExit()
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard p.terminationStatus == 0 else { throw AppError.message(L("Проверь SOCKS5 и правила маршрутизации. ", "Check SOCKS5 and routing rules. ") + String(detail.prefix(1000))) }
        }.value
    }
}
