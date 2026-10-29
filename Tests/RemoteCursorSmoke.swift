import AppKit
import Darwin

@main struct RemoteCursorSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var now = 0.0, hides = 0, shows = 0
        var current: NSCursor? = .arrow, messages: [RemoteCursor] = []
        let monitor = GuestRemoteCursor(currentCursor: { current }, hide: { hides += 1; return true }, show: { shows += 1 }, clock: { now })
        monitor.send = { messages.append($0) }
        monitor.setEnabled(true); precondition(hides == 1 && messages.count == 1)
        monitor.tick(); precondition(messages.count == 1, "unchanged cursor flooded link")
        current = .iBeam; monitor.tick(); precondition(messages.count == 2)
        precondition(messages.last?.cursor()?.hotSpot == NSCursor.iBeam.hotSpot)
        now = 6; monitor.setEnabled(true); precondition(hides == 1, "lease renewal hid cursor twice")
        now = 10; monitor.tick(); precondition(shows == 0)
        now = 15; monitor.tick(); precondition(shows == 1, "expired lease left cursor hidden")
        monitor.stop(); precondition(shows == 1)
        monitor.setEnabled(true); monitor.stop(); precondition(shows == 2 && hides == 2)
        var malformed = messages[0]; malformed.png = Data(repeating: 0, count: 20); precondition(malformed.cursor() == nil)
        malformed = messages[0]; malformed.width = .nan; precondition(malformed.cursor() == nil)
        malformed = messages[0]; malformed.png.replaceSubrange(16..<20, with: [0xff, 0xff, 0xff, 0xff]); precondition(malformed.cursor() == nil)
        let hostBoard = NSPasteboard.withUniqueName(), guestBoard = NSPasteboard.withUniqueName()
        defer { hostBoard.releaseGlobally(); guestBoard.releaseGlobally() }
        var fds: [Int32] = [-1, -1]; precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let host = ClipboardEndpoint(fd: fds[0], host: true, pasteboard: hostBoard, clipboardEnabled: false)
        let guest = ClipboardEndpoint(fd: fds[1], host: false, pasteboard: guestBoard, clipboardEnabled: false)
        var active = false, received: RemoteCursor?
        guest.onRemoteCursor = { active = $0 }
        let hostChange = hostBoard.changeCount, guestChange = guestBoard.changeCount
        host.start(); guest.start()
        defer { host.stop(); guest.stop() }
        func until(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "cursor relay timed out")
        }
        until { host.connected && guest.connected }
        host.setRemoteRelay { if $0.kind == "cursor" { received = $0.cursor } }
        until { active }
        guest.publishCursor(messages[0]); until { received != nil }
        precondition(received?.png == messages[0].png)
        // A client cannot turn off the lease or inject a cursor command to Tools.
        host.receiveRemote(ClipboardMessage(kind: "remoteCursor", remoteCursor: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)); precondition(active)
        host.setRemoteRelay(nil); until { !active }
        precondition(hostBoard.changeCount == hostChange && guestBoard.changeCount == guestChange)
        print("PASS: cursor shape/hotspot, duplicate suppression, balanced hide/restore, renewed/expired lease, bounded PNG parser, Tools relay without touching either pasteboard")
    }
}
