import AppKit
import Network
import ScreenCaptureKit
import CoreImage

@MainActor final class StreamPattern: NSView {
    var tick = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.35, alpha: 1).setFill(); bounds.fill()
        NSColor.white.setStroke(); let outline = NSBezierPath(rect: bounds.insetBy(dx: 10, dy: 10)); outline.lineWidth = 20; outline.stroke()
        NSColor.systemBlue.setFill(); NSRect(x: CGFloat(tick % 300) + 40, y: 50, width: 30, height: 180).fill()
        let title = "Isola · Retina stream test\nABCDEFGHIJKLMNOPQRSTUVWXYZ\n0123456789 — small text"
        title.draw(at: NSPoint(x: 80, y: bounds.height - 130), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.white])
    }
}

@main struct RemoteStreamSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: capture integration requires existing Screen Recording permission"); return }
        var binding = RemoteChannelBinding()
        let controlID = UUID(), token = binding.begin(controlID)!
        precondition(binding.begin(UUID()) == nil)
        precondition(!binding.join(UUID(), channel: "video", token: "wrong"))
        precondition(binding.join(UUID(), channel: "video", token: token))
        precondition(!binding.join(UUID(), channel: "video", token: token))
        binding.reset(); precondition(!binding.join(UUID(), channel: "clipboard", token: token))
        let source = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 640, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false; source.hasShadow = false; source.ignoresMouseEvents = true; source.title = "Isola capture fixture"
        let pattern = StreamPattern(frame: source.contentLayoutRect); pattern.autoresizingMask = [.width, .height]; source.contentView = pattern; source.orderBack(nil)
        let animation = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { pattern.tick += 1; pattern.needsDisplay = true; pattern.displayIfNeeded() } }
        RunLoop.main.add(animation, forMode: .common)
        let parameters = try RemoteSecurity.parameters(password: nil), listener = try NWListener(using: parameters, on: .any)
        var port: NWEndpoint.Port?, links: [UUID: RemoteLink] = [:], roles: [String: RemoteLink] = [:]
        var capture: RemoteCapture?, viewport = RemoteViewport(width: 1280, height: 800, scale: 2)
        var failure: String?, ackCount = 0, inputCount = 0, lastFrame: RemoteVideo?, borderVerified = false
        let inspection = RemoteDecoder()
        var savedSample = false
        var heldBulk: (() -> Void)?, bulkBlocked = false
        func resize() {
            source.setContentSize(CGSize(width: Double(viewport.width) / source.backingScaleFactor, height: Double(viewport.height) / source.backingScaleFactor))
            pattern.needsDisplay = true; capture?.resize(viewport)
        }
        func startCapture() {
            guard capture == nil, roles.count == 3 else { return }
            resize()
            let next = RemoteCapture(); capture = next
            Task {
                do {
                    try await next.start(window: source, viewport: viewport, codecs: RemoteDecoder.codecs, send: { frame, sent in
                        DispatchQueue.main.async {
                            lastFrame = frame
                            roles["video"]?.send(RemotePacket(kind: "video", video: frame), completion: sent)
                        }
                        inspection.decode(frame) { sample in
                            guard let image = sample?.imageBuffer else { return }
                            if !savedSample {
                                savedSample = true
                                // VideoToolbox may return losslessly compressed GPU
                                // surfaces (&8v0). Never interpret their memory as NV12.
                                let ci = CIImage(cvPixelBuffer: image)
                                if let cg = CIContext().createCGImage(ci, from: ci.extent) {
                                    let bitmap = NSBitmapImageRep(cgImage: cg)
                                    let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
                                    let bright = [(8,8), (w-9,8), (8,h-9), (w-9,h-9)].allSatisfy { point in
                                        guard let color = bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB) else { return false }
                                        return color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9
                                    }
                                    if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: ".build/RemoteStreamSample.png")) }
                                    DispatchQueue.main.async { borderVerified = bright }
                                }
                            }
                        }
                    }, onError: { error in DispatchQueue.main.async { failure = error } })
                } catch { failure = error.localizedDescription }
            }
        }
        listener.stateUpdateHandler = { state in if case .ready = state { DispatchQueue.main.async { port = listener.port } } }
        listener.newConnectionHandler = { connection in
            let id = UUID(), link = RemoteLink(connection)
            link.onPacket = { packet, consumed in DispatchQueue.main.async {
                if packet.kind == "hello" {
                    let channel = packet.channel!
                    if channel == "control" {
                        let token = binding.begin(id)!; viewport = packet.viewport!
                        link.send(RemotePacket(kind: "welcome", version: RemoteSecurity.version, name: "Stream fixture", clipboardEnabled: false, syncKeyboard: false, token: token))
                    } else {
                        precondition(binding.join(id, channel: channel, token: packet.token))
                        link.send(RemotePacket(kind: "channelReady", channel: channel))
                    }
                    roles[channel] = link; startCapture()
                } else if packet.kind == "viewport", let next = packet.viewport { viewport = next; resize() }
                else if packet.kind == "frameAck" { ackCount += 1; capture?.acknowledge(packet.sequence!) }
                else if packet.kind == "ping" { link.send(RemotePacket(kind: "pong", timestamp: packet.timestamp)) }
                else if packet.kind == "input" { inputCount += 1 }
                else if packet.kind == "clipboard" { heldBulk = consumed; bulkBlocked = true; return }
                consumed()
            } }
            DispatchQueue.main.async { links[id] = link }; link.start()
        }
        func until(_ condition: () -> Bool, timeout: Double = 12) {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && failure == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), failure ?? "stream timed out: roles=\(roles.count), ack=\(ackCount), border=\(borderVerified), frame=\(lastFrame?.width ?? 0)x\(lastFrame?.height ?? 0), codec=\(lastFrame?.codec ?? "none"), viewport=\(viewport.width)x\(viewport.height), epoch=\(viewport.epoch)")
        }
        listener.start(queue: .main); until { port != nil }
        let peer = RemoteDiscovery.Peer(id: UUID().uuidString, name: "Stream fixture", endpoint: .hostPort(host: "127.0.0.1", port: port!))
        let client = try RemoteClient(peer: peer, password: nil, remember: false)
        let clientWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        clientWindow.isReleasedWhenClosed = false; clientWindow.ignoresMouseEvents = true; clientWindow.contentView = client.screen; clientWindow.orderBack(nil)
        defer { animation.invalidate(); capture?.stop(); client.disconnect(); links.values.forEach { $0.stop() }; listener.cancel(); source.close(); clientWindow.close(); inspection.stop() }
        until { client.hasFrame && ackCount > 5 && borderVerified }
        precondition(roles.count == 3 && lastFrame?.codec == "hevc")
        clientWindow.setContentSize(CGSize(width: 900, height: 500))
        until { viewport.width == 1800 && viewport.height == 1000 && lastFrame?.epoch == viewport.epoch }
        let before = ackCount
        client.quality = "responsive"
        until { lastFrame?.codec == "h264" && lastFrame?.width == 900 && ackCount > before + 3 }
        // Stop consuming a bulk socket and put an additional large payload behind
        // it. Control messages/video ACKs must continue on their own sockets.
        let bulk = roles["clipboard"]!
        bulk.send(RemotePacket(kind: "clipboard", clipboard: ClipboardMessage(kind: "clipboard", files: [ClipboardFile(name: "test.bin", data: Data(repeating: 42, count: 8 * 1024 * 1024))])))
        // Client -> server bulk using the production framing (a separate socket
        // is used below so no system pasteboard is touched by this test).
        let blocked = RemoteLink(NWConnection(host: "127.0.0.1", port: port!, using: parameters))
        blocked.onReady = { blocked.send(RemotePacket(kind: "clipboard", clipboard: ClipboardMessage(kind: "clipboard", files: [ClipboardFile(name: "test.bin", data: Data(repeating: 42, count: 8 * 1024 * 1024))]))) }
        blocked.start(); until { bulkBlocked }
        let ackBefore = ackCount
        client.screen.send?(RemoteInput(kind: "move", x: 0.25, y: 0.75, epoch: viewport.epoch))
        until { inputCount == 1 && ackCount > ackBefore + 4 }
        heldBulk?(); blocked.stop()
        client.disconnect(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)); precondition(client.ended)
        print("PASS: ScreenCaptureKit → hardware HEVC/H.264 → three TLS sockets → real RemoteClient decoder/display; no capture margins; Retina resize, codec switch, input while bulk blocked, clean disconnect")
    }
}
