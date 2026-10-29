import AppKit
import Darwin

@main struct RemoteClipboardSmoke {
    @MainActor static func main() throws {
        let owner = NSPasteboard.withUniqueName(), guest = NSPasteboard.withUniqueName(), client = NSPasteboard.withUniqueName()
        defer { owner.releaseGlobally(); guest.releaseGlobally(); client.releaseGlobally() }
        func set(_ board: NSPasteboard, _ text: String) { board.clearContents(); board.setString(text, forType: .string) }
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        var sockets: [Int32] = [-1, -1]; precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        var ownerLayout = "com.apple.keylayout.US", guestLayout = "com.apple.keylayout.US", clientLayout = "com.apple.keylayout.Russian"
        let bridge = ClipboardEndpoint(fd: sockets[0], host: true, pasteboard: owner, syncKeyboard: true, inputSourceProvider: { ownerLayout }, inputSourceReceiver: { ownerLayout = $0 })
        let tools = ClipboardEndpoint(fd: sockets[1], host: false, pasteboard: guest, inputSourceProvider: { guestLayout }, inputSourceReceiver: { guestLayout = $0 })
        var sleepValues: [Bool] = []; tools.onPreventSleep = { sleepValues.append($0) }
        bridge.start(); tools.start(); pump()
        set(owner, "owner-private"); set(client, "client text")
        let remote = try RemoteClipboard(clipboard: true, keyboard: true, pasteboard: client, inputSourceProvider: { clientLayout }, inputSourceReceiver: { clientLayout = $0 }) { bridge.receiveRemote($0) }
        bridge.setRemoteRelay { remote.receive($0) }; pump()
        precondition(guest.string(forType: .string) == "client text")
        precondition(owner.string(forType: .string) == "owner-private", "owner clipboard leaked/replaced")
        precondition(guestLayout == clientLayout && ownerLayout == "com.apple.keylayout.US")
        set(guest, "guest text"); guestLayout = "com.apple.keylayout.ABC"; pump()
        precondition(client.string(forType: .string) == "guest text" && clientLayout == guestLayout)
        precondition(owner.string(forType: .string) == "owner-private" && ownerLayout == "com.apple.keylayout.US")
        set(owner, "new owner secret"); ownerLayout = "com.apple.keylayout.French"; pump()
        precondition(guest.string(forType: .string) == "guest text" && guestLayout == "com.apple.keylayout.ABC")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0xCD, count: 2 * 1024 * 1024).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        client.clearContents(); client.writeObjects([temp as NSURL]); pump()
        let files = guest.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL]
        let contents = try Data(contentsOf: files[0]); precondition(contents == Data(repeating: 0xCD, count: 2 * 1024 * 1024))
        let before = sleepValues.count
        bridge.receiveRemote(ClipboardMessage(kind: "sleep", preventSleep: true)); pump()
        precondition(sleepValues.count == before, "remote client changed host-controlled guest sleep")
        bridge.setPreventSleep(true); pump(); precondition(sleepValues.last == true)
        bridge.tick(now: Date().addingTimeInterval(25)); pump(); precondition(sleepValues.suffix(2) == [true, true], "sleep preference was not refreshed")
        remote.stop(); bridge.setRemoteRelay(nil); pump()
        precondition(guestLayout == ownerLayout, "owner layout not restored after disconnect")
        precondition(owner.string(forType: .string) == "new owner secret")
        bridge.stop(); tools.stop()
        print("PASS: remote text/files/layout, host clipboard/layout isolation, remote control-message rejection, sleep refresh, owner layout restored")
    }
}
