import AppKit
import Darwin

@main struct ClipboardTransferSmoke {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("IsolaTransferTest-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let a = NSPasteboard.withUniqueName(), b = NSPasteboard.withUniqueName()
        defer { a.releaseGlobally(); b.releaseGlobally(); try? fm.removeItem(at: root) }
        var pair: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let host = ClipboardEndpoint(fd: pair[0], host: true, pasteboard: a)
        let guest = ClipboardEndpoint(fd: pair[1], host: false, pasteboard: b)
        defer { host.stop(); guest.stop() }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "clipboard transfer timed out")
        }
        func urls(_ board: NSPasteboard) -> [URL] {
            board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }
        host.start(); guest.start(); wait { host.connected && guest.connected }
        // Non-text binary data detects corruption and the old Base64 expansion.
        var payload = Data(count: 32 * 1024 * 1024)
        payload.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in bytes.indices { bytes[i] = UInt8((i * 7 + i / 257) % 251) }
        }
        let message = ClipboardMessage(kind: "clipboard", files: [ClipboardFile(name: "large.bin", data: payload)])
        let encoded = try ClipboardTransport.encode(message, binary: true)
        precondition(encoded.count < payload.count + 4096, "binary payload expanded")
        let file = root.appendingPathComponent("large.bin"), empty = root.appendingPathComponent("empty.txt")
        try payload.write(to: file); try Data().write(to: empty)
        var ticks = 0, longestGap = 0.0, lastTick = Date()
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let now = Date(); longestGap = max(longestGap, now.timeIntervalSince(lastTick)); lastTick = now; ticks += 1
        }
        defer { heartbeat.invalidate() }
        let started = Date()
        a.clearContents(); a.writeObjects([file as NSURL, empty as NSURL])
        wait { urls(b).count == 2 }
        let duration = Date().timeIntervalSince(started)
        let copied = urls(b)
        precondition(tryData(copied[0]) == payload && tryData(copied[1]).isEmpty)
        precondition(ticks > 0, "main run loop did not make progress")
        let count = a.changeCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        precondition(a.changeCount == count, "file clipboard echoed")
        b.clearContents(); b.writeObjects([file as NSURL])
        wait { urls(a).count == 1 && urls(a)[0] != file }
        precondition(tryData(urls(a)[0]) == payload, "reverse file corrupted")
        // A slow file job must not replace the user's newer text selection.
        a.clearContents(); a.writeObjects([file as NSURL]); host.tick()
        a.clearContents(); a.setString("newer selection", forType: .string)
        wait { b.string(forType: .string) == "newer selection" }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(b.string(forType: .string) == "newer selection")
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        a.clearContents(); a.writeObjects([link as NSURL])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(b.string(forType: .string) == "newer selection", "symlink was transferred")
        print(String(format: "PASS: binary 32 MiB + empty file, both directions, cancellation, symlink rejection; %.3f s, main-loop max gap %.3f s", duration, longestGap))
        try legacyCompatibility()
    }
    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }
    @MainActor static func legacyCompatibility() throws {
        let board = NSPasteboard.withUniqueName()
        var pair: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let endpoint = ClipboardEndpoint(fd: pair[0], host: true, pasteboard: board)
        defer { endpoint.stop(); Darwin.close(pair[1]); board.releaseGlobally() }
        _ = fcntl(pair[1], F_SETFL, O_NONBLOCK)
        board.clearContents(); board.setString("legacy text", forType: .string)
        endpoint.start()
        func send(_ message: ClipboardMessage) throws {
            let bytes = try JSONEncoder().encode(message)
            var frame = Data([0, 0, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]); frame.append(bytes)
            precondition(frame.withUnsafeBytes { Darwin.write(pair[1], $0.baseAddress, $0.count) } == frame.count)
        }
        try send(ClipboardMessage(kind: "hello", version: 5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        var bytes = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(pair[1], &bytes, bytes.count)
        precondition(n > 4)
        var data = Data(bytes.prefix(n)), messages: [ClipboardMessage] = []
        while data.count >= 4 {
            let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let payload = data.dropFirst(4).prefix(length)
            messages.append(try JSONDecoder().decode(ClipboardMessage.self, from: Data(payload)))
            data.removeFirst(length + 4)
        }
        precondition(messages.contains { $0.kind == "hello" && $0.desktop == false && $0.downloads == false })
        precondition(messages.contains { $0.formats?[NSPasteboard.PasteboardType.string.rawValue] == Data("legacy text".utf8) })
        try send(ClipboardMessage(kind: "clipboard", files: [ClipboardFile(name: "../outside", data: Data([1]))]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(board.string(forType: .string) == "legacy text")
        print("PASS: v5 JSON compatibility, old mirror disable flags, traversal rejection")
    }
}
