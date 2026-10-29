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
    var preventSleep: Bool?
    var remoteCursor: Bool?
    var cursor: RemoteCursor?
}

// Bounded clipboard and input-source transport; received files only enter a private staging directory.
@MainActor final class ClipboardEndpoint {
    static let maximumFrame = ClipboardTransport.maximumFrame
    nonisolated static let maximumFilesSize = 64 * 1024 * 1024
    static let types: [NSPasteboard.PasteboardType] = [.string, .png, .tiff]
    private var transport: ClipboardTransport!
    private let filesQueue = DispatchQueue(label: "org.isola.clipboard.files", qos: .userInitiated)
    private var publishingFiles = false
    private var receivingFiles = false
    private var pendingFiles: ([ClipboardFile], UInt64, Int)?
    private var clipboardRevision: UInt64 = 0
    private let pasteboard: NSPasteboard
    private let host: Bool
    private var timer: Timer?
    private var clipboardEnabled: Bool
    private var syncKeyboard: Bool
    private var lastInputSource: String?
    private var sourceRevision: UInt64 = 0
    private var winningSourceIsHost = true
    private var awaitingInitialSource = false
    private var lastTick = Date()
    private var lastHeartbeat = Date.distantPast
    private var lastReceived = Date()
    private var lastSleepRefresh = Date.distantPast
    var onStatus: ((String) -> Void)?
    var onToolsVersion: ((Int?) -> Void)?
    var optimizePerformance = false
    var onPerformance: ((Bool) throws -> Void)?
    var onPerformanceStatus: ((String) -> Void)?
    private var peerVersion = 0
    var preventSleep = false
    var onPreventSleep: ((Bool) throws -> Void)?
    var onSleepStatus: ((String) -> Void)?
    var onRemoteCursor: ((Bool) -> Void)?
    var onKeyboardStatus: ((String) -> Void)?
    private let inputSourceProvider: (() -> String?)?
    private let inputSourceReceiver: ((String) -> Void)?
    private var changeCount: Int
    private(set) var connected = false
    private(set) var closed = false
    private var remoteRelay: ((ClipboardMessage) -> Void)?

    // During remote control the guest belongs to the client's clipboard/layout.
    // The host's pasteboard and input source are never read or overwritten.
    func setRemoteRelay(_ relay: ((ClipboardMessage) -> Void)?) {
        guard host else { return }
        clipboardRevision += 1; pendingFiles = nil
        remoteRelay = relay; changeCount = pasteboard.changeCount; lastInputSource = nil
        if connected, peerVersion >= 8 { enqueue(ClipboardMessage(kind: "remoteCursor", remoteCursor: relay != nil)) }
        if connected, let relay { relay(ClipboardMessage(kind: "hello", version: 8)) }
    }
    func receiveRemote(_ message: ClipboardMessage) {
        guard host, connected, remoteRelay != nil else { return }
        if message.kind == "clipboard", clipboardEnabled { enqueue(message) }
        if message.kind == "inputSource", syncKeyboard, let source = message.inputSource, source.utf8.count < 512 {
            sourceRevision = sourceRevision == UInt64.max ? 1 : sourceRevision + 1
            winningSourceIsHost = true
            enqueue(ClipboardMessage(kind: "inputSource", inputSource: source, sourceRevision: sourceRevision))
        }
    }

    init(fd: Int32, host: Bool, pasteboard: NSPasteboard = .general, clipboardEnabled: Bool = true, syncKeyboard: Bool = false, inputSourceProvider: (() -> String?)? = nil, inputSourceReceiver: ((String) -> Void)? = nil) {
        self.inputSourceProvider = inputSourceProvider; self.inputSourceReceiver = inputSourceReceiver
        self.clipboardEnabled = clipboardEnabled; self.syncKeyboard = syncKeyboard
        self.host = host; self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        transport = ClipboardTransport(fd: fd, receive: { [weak self] message, consumed in
            DispatchQueue.main.async { defer { consumed() }; guard let self, !self.closed else { return }; self.receive(message) }
        }, onClose: { [weak self] in DispatchQueue.main.async { self?.stop() } })
    }
    func start() {
        guard timer == nil, !closed else { return }
        transport.start()
        if !host { lastHeartbeat = Date(); enqueue(ClipboardMessage(kind: "hello", version: 8)) }
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func stop() {
        guard !closed else { return }
        closed = true; connected = false; timer?.invalidate(); timer = nil
        if host { onToolsVersion?(nil) }
        clipboardRevision += 1; pendingFiles = nil
        onRemoteCursor?(false)
        transport.stop()
    }
    deinit { transport?.stop() }
    func tick(now: Date = Date()) {
        guard !closed else { return }
        if connected && peerVersion >= 6 && !host && syncKeyboard && now.timeIntervalSince(lastTick) > 4 {
            // After guest sleep, a stale input-source notification must not
            // overwrite the host. Ask the host to establish the current layout.
            awaitingInitialSource = true
            enqueue(ClipboardMessage(kind: "keyboardResync", sourceRevision: sourceRevision))
        }
        lastTick = now
        if !host, !connected, now.timeIntervalSince(lastHeartbeat) > 2 {
            lastHeartbeat = now; enqueue(ClipboardMessage(kind: "hello", version: 8))
        }
        if host, connected, peerVersion >= 6, now.timeIntervalSince(lastSleepRefresh) > 20 {
            lastSleepRefresh = now; enqueue(ClipboardMessage(kind: "sleep", preventSleep: preventSleep))
        }
        if remoteRelay == nil && connected && clipboardEnabled && !publishingFiles && pasteboard.changeCount != changeCount { publish() }
        if connected && syncKeyboard && !awaitingInitialSource { publishInputSource() }
        if connected && Date().timeIntervalSince(lastHeartbeat) > 2 {
            lastHeartbeat = Date(); enqueue(ClipboardMessage(kind: "ping", version: 8))
            if host, peerVersion >= 8, remoteRelay != nil { enqueue(ClipboardMessage(kind: "remoteCursor", remoteCursor: true)) }
            if host && Date().timeIntervalSince(lastReceived) > 8 { onStatus?("Нет ответа Isola Tools. Переустановите помощник в госте.") }
        }
    }
    private func enqueue(_ message: ClipboardMessage) {
        // Hello stays JSON so old Tools can negotiate before binary frames begin.
        transport.send(message, binary: peerVersion >= 6 && message.kind != "hello")
    }
    private func publish() {
        guard clipboardEnabled, remoteRelay == nil else { return }
        changeCount = pasteboard.changeCount
        clipboardRevision += 1; pendingFiles = nil
        if (pasteboard.types ?? []).contains(.fileURL) {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty, urls.count <= 128 else { return }
            publishingFiles = true
            let revision = clipboardRevision, snapshot = changeCount
            filesQueue.async { [weak self] in
                let files = Self.readFiles(urls)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.publishingFiles = false
                    guard !self.closed, self.clipboardRevision == revision, self.pasteboard.changeCount == snapshot else { return }
                    if let files { self.enqueue(ClipboardMessage(kind: "clipboard", files: files)) }
                    else { self.onStatus?(L("Файлы не скопированы: нужны обычные файлы до 64 МиБ суммарно. Для папок и больших файлов используй общий доступ.", "Files were not copied: use regular files up to 64 MiB total. Share a folder for larger files or directories.")) }
                }
            }
            return
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
        if message.kind == "ping" { enqueue(ClipboardMessage(kind: "pong", version: 8)); return }
        if message.kind == "pong" { return }
        if connected, !host, message.kind == "remoteCursor", peerVersion >= 8 { onRemoteCursor?(message.remoteCursor == true); return }
        if connected, let relay = remoteRelay {
            if message.kind == "cursor", let cursor = message.cursor, cursor.valid { relay(message); return }
            if message.kind == "clipboard" { if clipboardEnabled { relay(message) }; return }
            if ["inputSource", "keyboardResync", "keyboardResult"].contains(message.kind) {
                guard syncKeyboard else { return }
                if message.kind == "keyboardResync" { sourceRevision = max(sourceRevision, min(message.sourceRevision ?? 0, UInt64.max - 2)) }
                if message.kind == "inputSource" {
                    let revision = message.sourceRevision ?? (sourceRevision + 1)
                    guard revision > sourceRevision else { return }
                    sourceRevision = min(revision, UInt64.max - 2); winningSourceIsHost = false
                }
                var copy = message; copy.sourceRevision = nil; relay(copy); return
            }
        }
        if connected && host && syncKeyboard && message.kind == "keyboardResync" {
            sourceRevision = max(sourceRevision, min(message.sourceRevision ?? 0, UInt64.max - 2))
            lastInputSource = nil; publishInputSource(); return
        }
        if connected && !host && message.kind == "performance", let enabled = message.optimizePerformance {
            applyPerformance(enabled); return
        }
        if connected && !host && message.kind == "sleep", let enabled = message.preventSleep { applySleep(enabled); return }
        if host && message.kind == "sleepResult", let status = message.status {
            onSleepStatus?(peerVersion < 7 ? L("Обнови Isola Tools: в новой версии исправлено удержание гостя от сна.", "Update Isola Tools for the guest sleep fix.") : status); return
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
                onToolsVersion?(peerVersion)
                lastSleepRefresh = Date()
                enqueue(ClipboardMessage(kind: "hello", clipboardEnabled: clipboardEnabled, syncKeyboard: syncKeyboard, version: 8, desktop: false, downloads: false, optimizePerformance: optimizePerformance, preventSleep: preventSleep))
                publish(); lastInputSource = nil
                remoteRelay?(ClipboardMessage(kind: "hello", version: 8))
                if peerVersion >= 8 { enqueue(ClipboardMessage(kind: "remoteCursor", remoteCursor: remoteRelay != nil)) }
                if peerVersion < 5 { onPerformanceStatus?("Update Isola Tools to control visual effects.") }
                if peerVersion < 7 { onSleepStatus?("Update Isola Tools to control guest sleep.") }
                onStatus?((message.version ?? 0) >= 7 ? "Isola Tools подключён" : "Обновите Isola Tools: в госте старая версия помощника.")
            } else {
                clipboardEnabled = message.clipboardEnabled ?? true
                syncKeyboard = message.syncKeyboard ?? false
                awaitingInitialSource = syncKeyboard
                if let enabled = message.optimizePerformance { applyPerformance(enabled) }
                if let enabled = message.preventSleep { applySleep(enabled) }
            }
            return
        }
        if connected && (syncKeyboard || !host) && message.kind == "inputSource", let identifier = message.inputSource, identifier.utf8.count < 512 {
            let remoteRevision = message.sourceRevision ?? (sourceRevision == UInt64.max ? 1 : sourceRevision + 1)
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
        clipboardRevision += 1; pendingFiles = nil
        if let files = message.files { receiveFiles(files); return }
        guard let formats = message.formats,
              formats.values.reduce(0, { $0 + $1.count }) <= 10 * 1024 * 1024,
              formats.keys.allSatisfy({ key in Self.types.contains(where: { $0.rawValue == key }) }) else { return }
        pasteboard.clearContents()
        for (type, data) in formats { pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        changeCount = pasteboard.changeCount
    }
    nonisolated private static func readFiles(_ urls: [URL]) -> [ClipboardFile]? {
        var files: [ClipboardFile] = [], size = 0
        for url in urls {
            // Opening with O_NOFOLLOW and checking the descriptor avoids a symlink
            // swap or a file growing past the memory limit between stat and read.
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_size <= maximumFilesSize - size else { return nil }
            let bytes: Data
            do { bytes = try file.read(upToCount: maximumFilesSize - size + 1) ?? Data() } catch { return nil }
            guard bytes.count <= maximumFilesSize - size else { return nil }
            size += bytes.count; files.append(ClipboardFile(name: url.lastPathComponent, data: bytes))
        }
        return files
    }
    private func receiveFiles(_ files: [ClipboardFile]) {
        guard !files.isEmpty, files.count <= 128,
              files.reduce(0, { $0 + $1.data.count }) <= Self.maximumFilesSize,
              files.allSatisfy({ !$0.name.isEmpty && $0.name != "." && $0.name != ".." && !$0.name.contains("/") && !$0.name.contains(":") && !$0.name.contains("\0") }) else { return }
        pendingFiles = (files, clipboardRevision, pasteboard.changeCount)
        writePendingFiles()
    }
    private func writePendingFiles() {
        guard !receivingFiles, let (files, revision, snapshot) = pendingFiles else { return }
        pendingFiles = nil; receivingFiles = true
        filesQueue.async { [weak self] in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("isola-clipboard-" + UUID().uuidString)
            var urls: [URL] = []
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                for (index, file) in files.enumerated() {
                    let directory = root.appendingPathComponent(String(index))
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    let url = directory.appendingPathComponent(file.name)
                    try file.data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    urls.append(url)
                }
            } catch { urls = [] }
            let completed = urls
            DispatchQueue.main.async {
                guard let self else { try? FileManager.default.removeItem(at: root); return }
                self.receivingFiles = false
                if !self.closed, self.clipboardRevision == revision, self.pasteboard.changeCount == snapshot, !completed.isEmpty {
                    self.pasteboard.clearContents(); self.pasteboard.writeObjects(completed as [NSURL])
                    self.changeCount = self.pasteboard.changeCount
                    // Earlier URLs remain available to apps that retained them.
                } else { self.filesQueue.async { try? FileManager.default.removeItem(at: root) } }
                self.writePendingFiles()
            }
        }
    }
    func setPreventSleep(_ enabled: Bool) {
        preventSleep = enabled
        lastSleepRefresh = Date()
        guard connected else { onSleepStatus?(L("Ожидание Isola Tools…", "Waiting for Isola Tools…")); return }
        guard peerVersion >= 6 else { onSleepStatus?(L("Обнови Isola Tools для управления сном гостя.", "Update Isola Tools to control guest sleep.")); return }
        onSleepStatus?(L("Ожидаем подтверждение из гостя…", "Waiting for confirmation from the guest…"))
        enqueue(ClipboardMessage(kind: "sleep", preventSleep: enabled))
    }
    private func applySleep(_ enabled: Bool) {
        guard let onPreventSleep else { return }
        do {
            try onPreventSleep(enabled)
            enqueue(ClipboardMessage(kind: "sleepResult", status: enabled ? L("Гость подтвердил: caffeinate -dis запущен.", "Guest confirmed: caffeinate -dis is running.") : L("Сон гостя разрешён.", "Guest sleep is allowed."), success: true))
        } catch { enqueue(ClipboardMessage(kind: "sleepResult", status: error.localizedDescription, success: false)) }
    }
    func publishCursor(_ cursor: RemoteCursor) { if !host, connected, peerVersion >= 8 { enqueue(ClipboardMessage(kind: "cursor", cursor: cursor)) } }
    func reportSleepError(_ message: String) { enqueue(ClipboardMessage(kind: "sleepResult", status: message, success: false)) }
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
        guard remoteRelay == nil else { return }
        let value = inputSourceProvider?() ?? InputSources.current
        guard let identifier = value, identifier != lastInputSource else { return }
        lastInputSource = identifier
        sourceRevision = sourceRevision == UInt64.max ? 1 : sourceRevision + 1; winningSourceIsHost = host
        enqueue(ClipboardMessage(kind: "inputSource", inputSource: identifier, sourceRevision: sourceRevision))
    }
}
