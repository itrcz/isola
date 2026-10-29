import AppKit
import Network
import SwiftUI
import Virtualization

@MainActor final class RemoteClipboard {
    private let endpoint: ClipboardEndpoint
    private var transport: ClipboardTransport!
    init(clipboard: Bool, keyboard: Bool, pasteboard: NSPasteboard = .general, inputSourceProvider: (() -> String?)? = nil, inputSourceReceiver: ((String) -> Void)? = nil, send: @escaping (ClipboardMessage) -> Void) throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw RemoteSecurity.failure("Clipboard socket unavailable.") }
        for fd in sockets { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        endpoint = ClipboardEndpoint(fd: sockets[0], host: true, pasteboard: pasteboard, clipboardEnabled: clipboard, syncKeyboard: keyboard, inputSourceProvider: inputSourceProvider, inputSourceReceiver: inputSourceReceiver)
        transport = ClipboardTransport(fd: sockets[1], receive: { [weak self] message, consumed in
            DispatchQueue.main.async {
                defer { consumed() }; guard let self else { return }
                if message.kind == "ping" { self.receive(ClipboardMessage(kind: "pong", version: 6)) }
                else if ["clipboard", "inputSource"].contains(message.kind) { send(message) }
            }
        }, onClose: {})
        transport.start(); endpoint.start()
    }
    func receive(_ message: ClipboardMessage) { transport.send(message, binary: message.kind != "hello") }
    func switchKeyboard() { _ = InputSources.cycle(); endpoint.publishInputSource() }
    func stop() { endpoint.stop(); transport.stop() }
}

@MainActor final class RemoteDiscovery: ObservableObject {
    struct Peer: Identifiable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        var protected = false
        var version = RemoteSecurity.version
    }
    @Published var peers: [Peer] = []
    @Published var error: String?
    private var browser: NWBrowser?
    func start() {
        guard browser == nil else { return }; error = nil
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteSecurity.serviceType, domain: "local."), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in DispatchQueue.main.async {
            guard let self, let browser, self.browser === browser else { return }
            var unique: [String: Peer] = [:]
            for result in results {
                guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
                guard case .bonjour(let txt) = result.metadata, ["1", "2"].contains(txt["version"] ?? "") else { continue }
                let peer = Peer(id: name + "." + type + "." + domain, name: name, endpoint: result.endpoint, protected: txt["auth"] != "open", version: Int(txt["version"] ?? "") ?? 0)
                unique[peer.id] = peer
            }
            self.peers = unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } }
        browser.stateUpdateHandler = { [weak self, weak browser] state in DispatchQueue.main.async {
            guard let self, let browser, self.browser === browser else { return }
            if case .failed(let error) = state { self.error = error.localizedDescription }
            if case .waiting(let error) = state { self.error = error.localizedDescription }
        } }
        browser.start(queue: .main)
    }
    func stop() { browser?.cancel(); browser = nil; peers = [] }
}

private final class RemoteVMWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor final class RemoteHost: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var passwordProtected = false
    private var password: String?
    private var resumeAfterPassword = false
    @Published private(set) var status = ""
    @Published private(set) var controlling = false
    weak var model: Model?
    private var listener: NWListener?
    private var links: [UUID: RemoteLink] = [:]
    private var controller: UUID?
    private var greeted = false
    private var binding = RemoteChannelBinding()
    private var videoLink: RemoteLink?
    private var clipboardLink: RemoteLink?
    private var viewport = RemoteViewport(width: 1920, height: 1200, scale: 2)
    private var clientCodecs = [String]()
    private var capture: RemoteCapture?
    private var streamWindow: NSWindow?
    private var input: RemoteInputTarget?
    private var heartbeat: Timer?
    private var lastReceived = Date()
    private var generation = UUID()
    init(model: Model) { self.model = model; passwordProtected = UserDefaults.standard.bool(forKey: "remote.protected." + model.folder.path) }
    func setEnabled(_ enabled: Bool) {
        if !enabled { stop(); return }
        do { try start() } catch { stop(); status = error.localizedDescription }
    }
    private func start() throws {
        guard listener == nil else { return }
        guard let model, model.running, !model.busy else { throw RemoteSecurity.failure(L("Сначала запусти VM.", "Start the VM first.")) }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RemoteSecurity.failure(L("Разреши Isola запись экрана в Системных настройках → Конфиденциальность. Затем включи доступ снова; macOS может потребовать перезапуск Isola.", "Allow Isola Screen Recording in System Settings → Privacy, then enable sharing again. macOS may require restarting Isola."))
        }
        if passwordProtected {
            password = password ?? RemoteSecurity.savedPassword(account: "host:" + model.folder.path)
            guard let password, !password.isEmpty else { throw RemoteSecurity.failure(L("Задай пароль для подключения.", "Set a connection password.")) }
        }
        let idKey = "remote.id." + model.folder.path
        let id = UserDefaults.standard.string(forKey: idKey) ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: idKey)
        let listener = try NWListener(using: RemoteSecurity.parameters(password: passwordProtected ? password : nil))
        var name = model.name + " @ " + (Host.current().localizedName ?? "Mac")
        while name.utf8.count > 48 { name.removeLast() }
        name += " · " + id.prefix(6)
        listener.service = NWListener.Service(name: name, type: RemoteSecurity.serviceType, domain: "local.", txtRecord: NWTXTRecord(["version": String(RemoteSecurity.version), "auth": passwordProtected ? "password" : "open"]))
        listener.newConnectionHandler = { [weak self, weak listener] connection in DispatchQueue.main.async {
            guard let self, let listener, self.listener === listener else { connection.cancel(); return }
            self.accept(connection)
        } }
        listener.stateUpdateHandler = { [weak self, weak listener] state in DispatchQueue.main.async {
            guard let self, let listener, self.listener === listener else { return }
            if case .ready = state { self.status = L("Доступна в локальной сети", "Available on the local network") }
            if case .failed(let error) = state { self.stop(); self.status = error.localizedDescription }
            if case .waiting(let error) = state { self.status = error.localizedDescription }
        } }
        self.listener = listener; enabled = true; status = L("Включаем доступ…", "Starting sharing…")
        listener.start(queue: .main)
    }
    private func accept(_ connection: NWConnection) {
        guard enabled, links.count < 6, RemoteLAN.allows(connection.endpoint) else { connection.cancel(); return }
        let id = UUID(), link = RemoteLink(connection, receiveLimit: 128 * 1024); links[id] = link
        link.onPacket = { [weak self, weak link] packet, consumed in DispatchQueue.main.async {
            defer { consumed() }
            guard let self, let link, self.links[id] === link else { return }
            if self.binding.channels[id] == nil { self.hello(packet, id: id, link: link); return }
            if self.binding.channels[id] == "control" { self.lastReceived = Date(); self.receive(packet, link: link) }
            else if self.binding.channels[id] == "clipboard", packet.kind == "clipboard", let message = packet.clipboard, message.kind == "clipboard" {
                self.model?.clipboardBridge?.receiveRemote(message)
            } else { link.stop() }
        } }
        link.onClose = { [weak self] error in DispatchQueue.main.async {
            guard let self else { return }
            self.links.removeValue(forKey: id)
            let channel = self.binding.remove(id)
            if channel != nil { self.endControl(); self.status = error ?? L("Доступна в локальной сети", "Available on the local network") }
        } }
        link.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak link] in
            guard let self, self.binding.channels[id] == nil else { return }; link?.stop()
        }
    }
    private func hello(_ packet: RemotePacket, id: UUID, link: RemoteLink) {
        guard packet.kind == "hello", packet.version == RemoteSecurity.version else {
            link.send(RemotePacket(kind: "error", name: L("Обнови Isola на обоих Mac до одной версии (0.8 или новее).", "Update Isola on both Macs to the same version (0.8 or later)."))) { link.stop() }; return
        }
        let channel = packet.channel ?? "control"
        if channel == "control" {
            guard controller == nil else {
                link.send(RemotePacket(kind: "error", name: L("VM уже управляется с другого Mac.", "Another Mac is already controlling this VM."))) { link.stop() }; return
            }
            guard let model, model.running, let viewport = packet.viewport, viewport.valid,
                  let codecs = packet.codecs, codecs.contains("h264") else { link.stop(); return }
            guard let token = binding.begin(id) else { link.stop(); return }
            controller = id; greeted = true
            self.viewport = viewport; clientCodecs = codecs.filter { ["h264", "hevc"].contains($0) }
            lastReceived = Date()
            link.send(RemotePacket(kind: "welcome", version: RemoteSecurity.version, name: model.name, clipboardEnabled: model.sharedClipboard, syncKeyboard: model.syncKeyboard, token: token))
            let accepted = Date()
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self, weak link] _ in MainActor.assumeIsolated {
                guard let self, let link else { return }
                if Date().timeIntervalSince(self.lastReceived) > 15 || (!self.controlling && Date().timeIntervalSince(accepted) > 10) { link.stop() }
                else { link.send(RemotePacket(kind: "ping")); self.capture?.checkHealth() }
            } }
            heartbeat = timer; RunLoop.main.add(timer, forMode: .common)
        } else {
            guard controller != nil, binding.join(id, channel: channel, token: packet.token) else { link.stop(); return }
            if channel == "video" { videoLink = link }
            else { clipboardLink = link; link.setReceiveLimit(RemoteLink.limit) }
            link.send(RemotePacket(kind: "channelReady", channel: channel))
            if let controller, let control = links[controller], videoLink != nil, clipboardLink != nil { beginControl(control) }
        }
    }
    private func receive(_ packet: RemotePacket, link: RemoteLink) {
        switch packet.kind {
        case "ping": link.send(RemotePacket(kind: "pong", timestamp: packet.timestamp))
        case "pong": break
        case "input": if controlling, let event = packet.input { input?.receive(event) }
        case "release": input?.releaseAll()
        case "activate": if controlling { relay(to: link) }
        case "clipboard":
            if let message = packet.clipboard, message.kind == "inputSource" { model?.clipboardBridge?.receiveRemote(message) }
        case "frameAck": if let sequence = packet.sequence { capture?.acknowledge(sequence) }
        case "viewport":
            guard let next = packet.viewport, next.valid, next.epoch > viewport.epoch else { return }
            viewport = next
            if controlling {
                do { try configureDisplay(); capture?.resize(next) }
                catch { link.send(RemotePacket(kind: "error", name: error.localizedDescription)) { link.stop() } }
            }
        default: break
        }
    }
    private func relay(to link: RemoteLink) {
        model?.clipboardBridge?.setRemoteRelay { [weak self, weak link] message in
            if message.kind == "clipboard" { self?.clipboardLink?.send(RemotePacket(kind: "clipboard", clipboard: message)) }
            else if message.kind == "cursor", let cursor = message.cursor { link?.send(RemotePacket(kind: "cursor", cursor: cursor)) }
            else { link?.send(RemotePacket(kind: "clipboard", clipboard: message)) }
        }
    }
    private func configureDisplay() throws {
        guard let window = streamWindow, let view = model?.displayView,
              let display = model?.machine?.graphicsDevices.first?.displays.first else { return }
        input?.releaseAll(); input?.epoch = viewport.epoch
        // Render at one host backing pixel per transmitted pixel, independent of
        // the client's scale. The guest's logical DPI follows the client.
        let scale = window.backingScaleFactor
        window.setContentSize(NSSize(width: Double(viewport.width) / scale, height: Double(viewport.height) / scale))
        view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        try display.reconfigure(configuration: VZMacGraphicsDisplayConfiguration(widthInPixels: viewport.width, heightInPixels: viewport.height, pixelsPerInch: Int(72 * viewport.scale)))
    }
    private func beginControl(_ link: RemoteLink) {
        guard let model, let machine = model.machine else { link.stop(); return }
        let view = model.displayView ?? VZVirtualMachineView()
        view.removeFromSuperview(); view.virtualMachine = machine
        view.automaticallyReconfiguresDisplay = false; view.capturesSystemKeys = false
        model.displayView = view
        let window = RemoteVMWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Isola VM Stream"; window.hasShadow = false
        window.ignoresMouseEvents = true; window.collectionBehavior = [.stationary, .ignoresCycle]
        window.backgroundColor = .black; window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 960, height: 600); view.autoresizingMask = [.width, .height]
        window.center(); window.orderBack(nil)
        streamWindow = window; input = RemoteInputTarget(view: view)
        do { try configureDisplay() }
        catch { link.send(RemotePacket(kind: "error", name: error.localizedDescription)) { link.stop() }; return }
        controlling = true; model.remoteControlActive = true
        status = L("Управляется с другого Mac", "Controlled by another Mac")
        relay(to: link)
        let capture = RemoteCapture(); self.capture = capture
        let generation = self.generation, initialViewport = viewport, video = videoLink, codecs = clientCodecs
        Task { [weak self, weak link] in
            guard let self, let link else { return }
            do {
                try await capture.start(window: window, viewport: initialViewport, codecs: codecs, send: { [weak video] frame, sent in
                    guard let video else { sent(); return }; video.send(RemotePacket(kind: "video", video: frame), completion: sent)
                }, onError: { [weak link] error in
                    link?.send(RemotePacket(kind: "error", name: error)) { link?.stop() }
                })
            } catch {
                guard self.generation == generation else { return }
                link.send(RemotePacket(kind: "error", name: error.localizedDescription)) { link.stop() }
            }
        }
    }
    func takeControl() {
        if let controller, let link = links[controller] {
            link.send(RemotePacket(kind: "error", name: L("Владелец вернул управление на хост.", "The owner took control on the host."))) { link.stop() }
        }
        endControl()
        if enabled { status = L("Доступна в локальной сети", "Available on the local network") }
    }
    private func endControl() {
        generation = UUID(); heartbeat?.invalidate(); heartbeat = nil
        let sessionLinks = Array(binding.channels.keys); binding.reset()
        for id in sessionLinks { links.removeValue(forKey: id)?.stop() }
        videoLink = nil; clipboardLink = nil
        input?.releaseAll(); input = nil; capture?.stop(); capture = nil
        model?.clipboardBridge?.setRemoteRelay(nil)
        if streamWindow != nil { model?.displayView?.removeFromSuperview(); streamWindow?.close(); streamWindow = nil }
        model?.displayView?.automaticallyReconfiguresDisplay = true
        model?.displayView?.capturesSystemKeys = !(model?.hostShortcuts ?? true)
        model?.remoteControlActive = false
        controller = nil; greeted = false; controlling = false
    }
    func stop() {
        listener?.newConnectionHandler = nil; listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        links.values.forEach { $0.stop() }; links.removeAll(); endControl()
        enabled = false; resumeAfterPassword = false; status = ""
    }
    func setPasswordProtected(_ protected: Bool) {
        guard let model else { return }
        let restart = enabled; stop(); passwordProtected = protected
        UserDefaults.standard.set(protected, forKey: "remote.protected." + model.folder.path)
        if restart {
            resumeAfterPassword = protected
            do { try start(); resumeAfterPassword = false } catch { status = error.localizedDescription }
        }
    }
    func savePassword(_ value: String) {
        guard let model, !value.isEmpty, value.utf8.count <= 1024 else { return }
        do {
            try RemoteSecurity.savePassword(value, account: "host:" + model.folder.path); password = value
            let restart = enabled || resumeAfterPassword; stop(); resumeAfterPassword = false
            if restart { try start() }
            else { status = L("Пароль сохранён.", "Password saved.") }
        } catch { status = error.localizedDescription }
    }

}

@MainActor final class RemoteClient: ObservableObject {
    let id = UUID()
    @Published var name: String
    @Published private(set) var status = L("Подключаемся…", "Connecting…")
    @Published private(set) var connected = false
    @Published private(set) var hasFrame = false
    @Published private(set) var ended = false
    @Published private(set) var statistics = ""
    @Published var quality = "retina" { didSet { if quality != oldValue { resize(screen.bounds.size, scale: screen.window?.backingScaleFactor ?? 2) } } }
    let screen = RemoteScreenView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    private let decoder = RemoteDecoder()
    private var link: RemoteLink?, videoLink: RemoteLink?, clipboardLink: RemoteLink?
    private var clipboard: RemoteClipboard?
    private var clipboardAllowed = false, keyboardAllowed = false, clipboardReady = false
    private var active = true
    private var timer: Timer?
    private var lastReceived = Date()
    private var viewport = RemoteViewport(width: 1280, height: 800, scale: 2)
    private var frameCount = 0, byteCount = 0
    private var statsTime = ProcessInfo.processInfo.systemUptime
    private var rtt: Double?
    private var lastStreamFrame: RemoteVideo?
    private var frameSequence: UInt64 = 0
    init(peer: RemoteDiscovery.Peer, password: String?, remember: Bool) throws {
        guard peer.version == RemoteSecurity.version else { throw RemoteSecurity.failure(L("Обнови Isola на хосте и клиенте до одной версии (0.8 или новее).", "Update Isola on the host and client to the same version (0.8 or later).")) }
        name = peer.name
        let parameters = try RemoteSecurity.parameters(password: password)
        let link = RemoteLink(NWConnection(to: peer.endpoint, using: parameters), receiveLimit: 128 * 1024); self.link = link
        link.onReady = { [weak self, weak link] in DispatchQueue.main.async {
            guard let self else { return }
            link?.send(RemotePacket(kind: "hello", version: RemoteSecurity.version, channel: "control", viewport: self.viewport, codecs: RemoteDecoder.codecs))
        } }
        link.onPacket = { [weak self] packet, consumed in DispatchQueue.main.async {
            defer { consumed() }; guard let self, !self.ended else { return }
            self.lastReceived = Date()
            if packet.kind == "welcome", packet.version == RemoteSecurity.version, !self.connected, let token = packet.token, token.utf8.count <= 128 {
                self.connected = true; self.name = String((packet.name ?? peer.name).prefix(100))
                self.clipboardAllowed = packet.clipboardEnabled == true; self.keyboardAllowed = packet.syncKeyboard == true
                self.status = L("Ожидаем изображение…", "Waiting for video…")
                if remember, let password { try? RemoteSecurity.savePassword(password, account: "peer:" + peer.id) }
                self.joinChannels(endpoint: peer.endpoint, parameters: parameters, token: token)
                self.resize(self.screen.bounds.size, scale: self.screen.window?.backingScaleFactor ?? 2)
            } else { self.receive(packet) }
        } }
        link.onClose = { [weak self] error in DispatchQueue.main.async {
            guard let self, !self.ended else { return }
            self.disconnect(message: !self.connected && peer.protected ? L("Подключение не удалось. Проверь пароль и доступность хоста.", "Connection failed. Check the password and host availability.") : error ?? L("Соединение закрыто хостом.", "The host closed the connection."))
        } }
        screen.send = { [weak self] input in guard let self, self.connected, self.active else { return }; self.link?.send(RemotePacket(kind: "input", input: input)) }
        screen.release = { [weak self] in self?.link?.send(RemotePacket(kind: "release")) }
        screen.switchKeyboard = { [weak self] in
            guard let self, self.keyboardAllowed, self.active else { return false }; self.clipboard?.switchKeyboard(); return true
        }
        screen.viewportChanged = { [weak self] size, scale in self?.resize(size, scale: scale) }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceived) > 15 { self.disconnect(message: L("Хост не отвечает. Проверь сеть и сон хоста.", "The host is not responding. Check the network and host sleep.")) }
            else { self.link?.send(RemotePacket(kind: "ping", timestamp: ProcessInfo.processInfo.systemUptime)); self.updateStatistics() }
        } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        link.start()
    }
    private func joinChannels(endpoint: NWEndpoint, parameters: NWParameters, token: String) {
        for channel in ["video", "clipboard"] {
            let stream = RemoteLink(NWConnection(to: endpoint, using: parameters), receiveLimit: channel == "video" ? 9 * 1024 * 1024 : RemoteLink.limit)
            if channel == "video" { videoLink = stream } else { clipboardLink = stream }
            stream.onReady = { [weak stream] in stream?.send(RemotePacket(kind: "hello", version: RemoteSecurity.version, channel: channel, token: token)) }
            stream.onPacket = { [weak self] packet, consumed in DispatchQueue.main.async {
                guard let self, !self.ended else { consumed(); return }
                if packet.kind == "channelReady", packet.channel == channel {
                    if channel == "clipboard" { self.clipboardReady = true; self.activateClipboard() }; consumed()
                } else if channel == "video", packet.kind == "video", let frame = packet.video {
                    self.receiveVideo(frame, consumed: consumed)
                } else if channel == "clipboard", packet.kind == "clipboard", let message = packet.clipboard, message.kind == "clipboard" {
                    if self.active { self.clipboard?.receive(message) }; consumed()
                } else { consumed(); self.disconnect(message: "Invalid remote channel.") }
            } }
            stream.onClose = { [weak self] error in DispatchQueue.main.async { self?.disconnect(message: error ?? L("Поток прерван.", "The stream was interrupted.")) } }
            stream.start()
        }
    }
    private func resize(_ size: CGSize, scale: CGFloat) {
        guard connected, !ended else { return }
        let next = RemoteViewport.fitting(width: size.width, height: size.height, backingScale: scale, quality: quality, epoch: viewport.epoch + 1)
        guard next.valid, next.width != viewport.width || next.height != viewport.height || next.scale != viewport.scale || next.quality != viewport.quality else { return }
        viewport = next; link?.send(RemotePacket(kind: "viewport", viewport: next))
    }
    private func receive(_ packet: RemotePacket) {
        switch packet.kind {
        case "ping": link?.send(RemotePacket(kind: "pong", timestamp: packet.timestamp))
        case "pong": if let sent = packet.timestamp, sent.isFinite { rtt = max(0, (ProcessInfo.processInfo.systemUptime - sent) * 1000) }
        case "error": disconnect(message: String((packet.name ?? "Connection failed.").prefix(1000)))
        case "cursor": if let cursor = packet.cursor { screen.setCursor(cursor) }
        case "clipboard":
            if connected, active, let message = packet.clipboard, ["hello", "inputSource", "keyboardResync", "keyboardResult"].contains(message.kind) { clipboard?.receive(message) }
        default: break
        }
    }
    private func receiveVideo(_ frame: RemoteVideo, consumed: @escaping () -> Void) {
        guard frame.sequence > frameSequence, frame.encodeMilliseconds.isFinite else { consumed(); disconnect(message: "Invalid video sequence."); return }
        frameSequence = frame.sequence
        decoder.decode(frame) { [weak self] sample in DispatchQueue.main.async {
            defer { consumed() }
            guard let self, !self.ended else { return }
            guard let sample else { self.disconnect(message: L("Не удалось декодировать видеопоток.", "Unable to decode the video stream.")); return }
            if frame.epoch >= self.viewport.epoch {
                self.screen.display(sample, frame: frame)
                if !self.hasFrame { self.hasFrame = true; self.status = L("Подключено · локальная сеть", "Connected · local network") }
            }
            self.link?.send(RemotePacket(kind: "frameAck", sequence: frame.sequence))
            self.frameCount += 1; self.byteCount += frame.bytes.count
            // Keep metadata only: the compressed payload can be released now.
            var metadata = frame; metadata.bytes = Data(); self.lastStreamFrame = metadata
            self.updateStatistics()
        } }
    }
    private func updateStatistics() {
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - statsTime
        guard elapsed >= 1, let frame = lastStreamFrame else { return }
        let ping = rtt.map { String(format: "%.0f ms", $0) } ?? "—"
        statistics = String(format: "%@ · %d×%d · %.0f fps · %.1f Mbps · RTT %@", frame.codec.uppercased(), frame.width, frame.height, Double(frameCount) / elapsed, Double(byteCount) * 8 / elapsed / 1_000_000, ping)
        frameCount = 0; byteCount = 0; statsTime = now
    }
    private func activateClipboard() {
        guard active, connected, clipboardReady, clipboard == nil else { return }
        do {
            clipboard = try RemoteClipboard(clipboard: clipboardAllowed, keyboard: keyboardAllowed) { [weak self] message in
                let channel = message.kind == "clipboard" ? self?.clipboardLink : self?.link
                channel?.send(RemotePacket(kind: "clipboard", clipboard: message))
            }
            link?.send(RemotePacket(kind: "activate"))
        } catch { status = error.localizedDescription }
    }
    func setActive(_ active: Bool) {
        self.active = active
        if active { activateClipboard() }
        else { link?.send(RemotePacket(kind: "release")); clipboard?.stop(); clipboard = nil }
    }
    func disconnect(message: String? = nil) {
        guard !ended else { return }
        ended = true; connected = false; status = message ?? L("Отключено", "Disconnected")
        timer?.invalidate(); timer = nil; clipboard?.stop(); clipboard = nil
        link?.stop(); videoLink?.stop(); clipboardLink?.stop(); link = nil; videoLink = nil; clipboardLink = nil; decoder.stop()
        screen.send = nil; screen.release = nil; screen.switchKeyboard = nil; screen.viewportChanged = nil
    }
}
