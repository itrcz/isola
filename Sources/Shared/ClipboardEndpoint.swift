import AppKit
import Darwin
import Carbon

struct ClipboardFile: Codable { var name: String; var data: Data }
struct ClipboardMessage: Codable {
    var kind: String
    var formats: [String: Data]?
    var files: [ClipboardFile]?
    var inputSource: String?
    var clipboardEnabled: Bool?
    var syncKeyboard: Bool?
    var version: Int?
    var desktop: Bool?
    var downloads: Bool?
    var status: String?
    var success: Bool?
    var sourceRevision: UInt64?
    var optimizePerformance: Bool?
}

// Bounded clipboard and input-source transport; received files only enter a private staging directory.
@MainActor final class ClipboardEndpoint {
    static let maximumFrame = 90 * 1024 * 1024
    static let maximumFilesSize = 64 * 1024 * 1024
    static let types: [NSPasteboard.PasteboardType] = [.string, .png, .tiff]
    private var fd: Int32
    private let pasteboard: NSPasteboard
    private let host: Bool
    private var timer: Timer?
    private var incoming = Data()
    private var outgoing = Data()
    private var written = 0
    private var pending: [String: Data] = [:]
    private var clipboardEnabled: Bool
    private var syncKeyboard: Bool
    private var lastInputSource: String?
    private var sourceRevision: UInt64 = 0
    private var winningSourceIsHost = true
    private var awaitingInitialSource = false
    private var lastHeartbeat = Date.distantPast
    private var lastReceived = Date()
    var onStatus: ((String) -> Void)?
    var onIntegration: ((Bool, Bool) -> String)?
    var optimizePerformance = false
    var onPerformance: ((Bool) throws -> Void)?
    var onPerformanceStatus: ((String) -> Void)?
    private var peerVersion = 0
    var mirrorDesktop = false
    var mirrorDownloads = false
    var onKeyboardStatus: ((String) -> Void)?
    private let inputSourceProvider: (() -> String?)?
    private let inputSourceReceiver: ((String) -> Void)?
    private var changeCount: Int
    private(set) var connected = false
    private(set) var closed = false

    init(fd: Int32, host: Bool, pasteboard: NSPasteboard = .general, clipboardEnabled: Bool = true, syncKeyboard: Bool = false, inputSourceProvider: (() -> String?)? = nil, inputSourceReceiver: ((String) -> Void)? = nil) {
        self.inputSourceProvider = inputSourceProvider; self.inputSourceReceiver = inputSourceReceiver
        self.clipboardEnabled = clipboardEnabled; self.syncKeyboard = syncKeyboard
        self.fd = fd; self.host = host; self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    func start() {
        if !host { enqueue(ClipboardMessage(kind: "hello", version: 5)) }
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func stop() {
        guard !closed else { return }
        closed = true; connected = false; timer?.invalidate(); timer = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        incoming.removeAll(); outgoing.removeAll(); pending.removeAll()
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func tick() {
        guard !closed else { return }
        readAvailable()
        guard !closed else { return }
        if connected && clipboardEnabled && pasteboard.changeCount != changeCount { publish() }
        if connected && syncKeyboard && !awaitingInitialSource { publishInputSource() }
        if connected && Date().timeIntervalSince(lastHeartbeat) > 2 {
            lastHeartbeat = Date(); enqueue(ClipboardMessage(kind: "ping", version: 5))
            if host && Date().timeIntervalSince(lastReceived) > 8 { onStatus?("Нет ответа Isola Tools. Переустановите помощник в госте.") }
        }
        flush()
    }
    private func enqueue(_ message: ClipboardMessage) {
        guard let payload = try? JSONEncoder().encode(message), payload.count <= Self.maximumFrame else { return }
        let n = UInt32(payload.count)
        var frame = Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        frame.append(payload)
        if outgoing.isEmpty { outgoing = frame; written = 0 } else { pending[message.kind] = frame }
    }
    private func publish() {
        guard clipboardEnabled else { return }
        changeCount = pasteboard.changeCount
        if (pasteboard.types ?? []).contains(.fileURL) {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty, urls.count <= 128 else { return }
            var files: [ClipboardFile] = []; var size = 0
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), values.isRegularFile == true, values.isSymbolicLink != true,
                      let count = values.fileSize, count <= Self.maximumFilesSize - size,
                      let data = try? Data(contentsOf: url), data.count <= Self.maximumFilesSize - size else { return }
                size += data.count; files.append(ClipboardFile(name: url.lastPathComponent, data: data))
            }
            enqueue(ClipboardMessage(kind: "clipboard", files: files)); return
        }
        var formats = [String: Data](); var size = 0
        for type in Self.types {
            if let data = pasteboard.data(forType: type) {
                // Base64 framing overhead must fit the maximum JSON frame size.
                if data.count > 10 * 1024 * 1024 || size + data.count > 10 * 1024 * 1024 { continue }
                formats[type.rawValue] = data; size += data.count
            }
        }
        // Unsupported types (e.g. file URLs) must not erase the other clipboard.
        guard !formats.isEmpty || (pasteboard.types ?? []).isEmpty else { return }
        enqueue(ClipboardMessage(kind: "clipboard", formats: formats))
    }
    private func receive(_ message: ClipboardMessage) {
        lastReceived = Date()
        if message.kind == "ping" { enqueue(ClipboardMessage(kind: "pong", version: 5)); return }
        if message.kind == "pong" { return }
        if connected && !host && message.kind == "performance", let enabled = message.optimizePerformance {
            applyPerformance(enabled); return
        }
        if host && message.kind == "performanceResult", let status = message.status { onPerformanceStatus?(status); return }
        if host && message.kind == "status", let status = message.status { onStatus?(status); return }
        if host && message.kind == "keyboardResult" {
            onKeyboardStatus?(message.success == true ? "Раскладка синхронизирована" : "Раскладка недоступна в госте: " + (message.inputSource ?? "")); return
        }
        if message.kind == "hello" {
            peerVersion = message.version ?? 0
            connected = true
            if host {
                enqueue(ClipboardMessage(kind: "hello", clipboardEnabled: clipboardEnabled, syncKeyboard: syncKeyboard, version: 5, desktop: mirrorDesktop, downloads: mirrorDownloads, optimizePerformance: optimizePerformance))
                publish(); lastInputSource = nil
                if peerVersion < 5 { onPerformanceStatus?("Update Isola Tools to control visual effects.") }
                onStatus?((message.version ?? 0) >= 4 ? "Isola Tools подключён" : "Обновите Isola Tools: в госте старая версия помощника.")
            } else {
                clipboardEnabled = message.clipboardEnabled ?? true
                syncKeyboard = message.syncKeyboard ?? false
                awaitingInitialSource = syncKeyboard
                if let enabled = message.optimizePerformance { applyPerformance(enabled) }
                if let onIntegration {
                    let result = onIntegration(message.desktop ?? false, message.downloads ?? false)
                    enqueue(ClipboardMessage(kind: "status", status: result))
                }
            }
            return
        }
        if connected && (syncKeyboard || !host) && message.kind == "inputSource", let identifier = message.inputSource, identifier.utf8.count < 512 {
            let remoteRevision = message.sourceRevision ?? (sourceRevision + 1)
            guard remoteRevision > sourceRevision || (remoteRevision == sourceRevision && !host && !winningSourceIsHost) else { return }
            sourceRevision = remoteRevision; winningSourceIsHost = !host
            let success: Bool
            if let inputSourceReceiver { inputSourceReceiver(identifier); success = true }
            else { success = InputSources.select(identifier) }
            // Do not echo a remotely selected source back as a local user change.
            lastInputSource = inputSourceProvider?() ?? InputSources.current ?? identifier
            awaitingInitialSource = false
            if !host { enqueue(ClipboardMessage(kind: "keyboardResult", inputSource: identifier, success: success)) }
            return
        }
        guard connected, clipboardEnabled, message.kind == "clipboard" else { return }
        if let files = message.files { receiveFiles(files); return }
        guard let formats = message.formats,
              formats.values.reduce(0, { $0 + $1.count }) <= 10 * 1024 * 1024,
              formats.keys.allSatisfy({ key in Self.types.contains(where: { $0.rawValue == key }) }) else { return }
        pasteboard.clearContents()
        for (type, data) in formats { pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        changeCount = pasteboard.changeCount
    }
    private func receiveFiles(_ files: [ClipboardFile]) {
        guard !files.isEmpty, files.count <= 128,
              files.reduce(0, { $0 + $1.data.count }) <= Self.maximumFilesSize,
              files.allSatisfy({ !$0.name.isEmpty && $0.name != "." && $0.name != ".." && !$0.name.contains("/") && !$0.name.contains(":") && !$0.name.contains("\0") }) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isola-clipboard-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var urls: [NSURL] = []
            for (index, file) in files.enumerated() {
                let directory = root.appendingPathComponent(String(index))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent(file.name)
                try file.data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                urls.append(url as NSURL)
            }
            pasteboard.clearContents(); pasteboard.writeObjects(urls)
            changeCount = pasteboard.changeCount
            // Keep earlier transfers usable by consumers that retained the previous URLs.
            // The OS owns cleanup of the per-user temporary directory.
        } catch { try? FileManager.default.removeItem(at: root) }
    }
    func setPerformance(_ enabled: Bool) {
        optimizePerformance = enabled
        guard connected else { onPerformanceStatus?("Waiting for Isola Tools…"); return }
        guard peerVersion >= 5 else { onPerformanceStatus?("Update Isola Tools to control visual effects."); return }
        onPerformanceStatus?("Applying guest visual settings…")
        enqueue(ClipboardMessage(kind: "performance", optimizePerformance: enabled))
    }
    private func applyPerformance(_ enabled: Bool) {
        guard let onPerformance else { return }
        do {
            try onPerformance(enabled)
            enqueue(ClipboardMessage(kind: "performanceResult", status: enabled ? "Reduced effects saved. Some apps need reopening or a guest logout." : "Previous visual settings restored. Some apps need reopening or a guest logout.", success: true, optimizePerformance: enabled))
        } catch {
            enqueue(ClipboardMessage(kind: "performanceResult", status: "Visual settings: " + error.localizedDescription, success: false, optimizePerformance: enabled))
        }
    }
    func reportStatus(_ status: String) { enqueue(ClipboardMessage(kind: "status", status: status)) }
    func publishInputSource() {
        let value = inputSourceProvider?() ?? InputSources.current
        guard let identifier = value, identifier != lastInputSource else { return }
        lastInputSource = identifier
        sourceRevision += 1; winningSourceIsHost = host
        enqueue(ClipboardMessage(kind: "inputSource", inputSource: identifier, sourceRevision: sourceRevision))
    }
    private func readAvailable() {
        var scratch = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<32 {
            let count = Darwin.read(fd, &scratch, scratch.count)
            if count == 0 { stop(); return }
            if count < 0 { if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { stop() }; return }
            incoming.append(contentsOf: scratch.prefix(count))
            while incoming.count >= 4 {
                let length = incoming.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0 && length <= Self.maximumFrame else { stop(); return }
                guard incoming.count >= length + 4 else { break }
                let start = incoming.startIndex + 4
                let payload = incoming.subdata(in: start..<(start + length))
                incoming.removeFirst(4 + length)
                guard let message = try? JSONDecoder().decode(ClipboardMessage.self, from: payload) else { stop(); return }
                receive(message)
            }
            if incoming.count > Self.maximumFrame + 4 { stop(); return }
        }
    }
    private func flush() {
        for _ in 0..<32 {
            if outgoing.isEmpty {
                guard let key = pending.keys.sorted().first, let next = pending.removeValue(forKey: key) else { return }
                outgoing = next; written = 0
            }
            let count = outgoing.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress!.advanced(by: written), min(outgoing.count - written, 65536)) }
            if count < 0 { if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { stop() }; return }
            if count == 0 { return }
            written += count
            if written == outgoing.count { outgoing.removeAll(keepingCapacity: false); written = 0 }
        }
    }
}
