import AppKit
import Darwin

@main struct ClipboardSmoke {
    @MainActor static func main() throws {
        let a = NSPasteboard.withUniqueName(), b = NSPasteboard.withUniqueName()
        defer { a.releaseGlobally(); b.releaseGlobally() }
        var sockets: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let host = ClipboardEndpoint(fd: sockets[0], host: true, pasteboard: a)
        let guest = ClipboardEndpoint(fd: sockets[1], host: false, pasteboard: b)
        defer { host.stop(); guest.stop() }
        a.clearContents(); a.setString("host initial — привет", forType: .string)
        b.clearContents(); b.setString("guest initial", forType: .string)
        host.start(); guest.start()
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
        pump(); precondition(host.connected && guest.connected)
        precondition(b.string(forType: .string) == "host initial — привет")
        b.clearContents(); b.setString("from guest 🐈", forType: .string)
        pump(); precondition(a.string(forType: .string) == "from guest 🐈")
        let count = a.changeCount
        pump(); precondition(a.changeCount == count, "clipboard echo loop")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1kAAAAASUVORK5CYII=")!
        a.clearContents(); a.setData(png, forType: .png)
        pump(); precondition(b.data(forType: .png) == png)
        b.clearContents(); b.setString("file:///private/not-shared", forType: .fileURL)
        pump(); precondition(a.data(forType: .png) == png, "unsupported file URL altered host")
        a.clearContents(); pump(); precondition((b.types ?? []).isEmpty)
        // This exceeds the per-item bound; no oversized frame should be sent.
        a.setData(Data(repeating: 65, count: 11 * 1024 * 1024), forType: .string)
        pump(); precondition((b.types ?? []).isEmpty)
        let fileRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fileRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileRoot) }
        let file = fileRoot.appendingPathComponent("картинка.png")
        try png.write(to: file)
        a.clearContents(); a.writeObjects([file as NSURL]); a.setString("картинка.png", forType: .string)
        pump()
        let urls = b.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL]
        precondition(urls.count == 1 && urls[0].lastPathComponent == file.lastPathComponent)
        let copied = try Data(contentsOf: urls[0]); precondition(copied == png, "file contents lost")
        precondition(b.string(forType: .string) != "картинка.png", "only file name copied")
        let before = a.changeCount; pump(); precondition(a.changeCount == before)
        b.clearContents(); b.writeObjects([file as NSURL]); pump()
        let reverse = a.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL]
        let reverseData = try Data(contentsOf: reverse[0]); precondition(reverseData == png)
        host.stop(); pump(); precondition(guest.closed)
        var malformed: [Int32] = [-1,-1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &malformed) == 0)
        let endpoint = ClipboardEndpoint(fd: malformed[0], host: true, pasteboard: a)
        let header: [UInt8] = [255,255,255,255]
        _ = header.withUnsafeBytes { Darwin.write(malformed[1], $0.baseAddress, $0.count) }
        endpoint.start(); pump(); precondition(endpoint.closed); Darwin.close(malformed[1])
        var layoutSockets: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &layoutSockets) == 0)
        var layout = "com.apple.keylayout.US"; var guestLayout = "com.apple.keylayout.ABC"; var selected: [String] = []
        let layoutHost = ClipboardEndpoint(fd: layoutSockets[0], host: true, pasteboard: a, clipboardEnabled: false, syncKeyboard: true, inputSourceProvider: { layout }, inputSourceReceiver: { layout = $0 })
        let layoutGuest = ClipboardEndpoint(fd: layoutSockets[1], host: false, pasteboard: b, inputSourceProvider: { guestLayout }, inputSourceReceiver: { selected.append($0); guestLayout = $0 })
        defer { layoutHost.stop(); layoutGuest.stop() }
        a.clearContents(); a.setString("host private", forType: .string)
        b.clearContents(); b.setString("guest private", forType: .string)
        var modes: [Bool] = []; var performanceStatus = ""
        var sleepModes: [Bool] = []
        layoutGuest.onPreventSleep = { sleepModes.append($0) }
        layoutGuest.onPerformance = { modes.append($0) }
        layoutHost.onPerformanceStatus = { performanceStatus = $0 }
        layoutHost.start(); layoutGuest.start()
        pump()
        precondition(selected == [layout])
        precondition(sleepModes == [false])
        layoutHost.setPreventSleep(true); pump()
        layoutHost.setPreventSleep(false); pump()
        precondition(sleepModes == [false, true, false])
        precondition(modes == [false], "initial performance preference missing")
        layoutHost.setPerformance(true)
        pump()
        precondition(modes == [false, true] && performanceStatus.contains("Reduced effects"))
        layoutHost.setPerformance(false)
        pump()
        precondition(modes == [false, true, false] && performanceStatus.contains("restored"))
        layout = "com.apple.keylayout.Russian"
        pump()
        precondition(selected == ["com.apple.keylayout.US", layout])
        guestLayout = "com.apple.keylayout.US"
        pump()
        precondition(layout == guestLayout, "guest layout did not reach host")
        let switches = selected.count
        pump()
        precondition(selected.count == switches, "layout echo loop")
        layout = "com.apple.keylayout.Russian"; guestLayout = "com.apple.keylayout.ABC"
        // Both events are queued before either side reads the competing update.
        layoutHost.publishInputSource(); layoutGuest.publishInputSource()
        pump()
        precondition(layout == guestLayout && layout == "com.apple.keylayout.Russian", "concurrent changes failed to converge")
        guestLayout = "com.apple.keylayout.ABC"
        layoutGuest.tick(now: Date().addingTimeInterval(10)); pump()
        precondition(layout == "com.apple.keylayout.Russian" && guestLayout == layout, "stale guest layout won after wake")
        precondition(a.string(forType: .string) == "host private" && b.string(forType: .string) == "guest private", "disabled clipboard changed")
        print("PASS: bidirectional layout sync without clipboard or echo loops,  handshake, bidirectional Unicode text, image, bidirectional files, no feedback, missing file rejection, clear, size bound, EOF, malformed frame")
    }
}
