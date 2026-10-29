import Foundation
import Darwin

@main struct SleepSmoke {
    @MainActor static func main() throws {
        let guest = SleepInhibitor(keepDisplayAwake: true)
        let host = SleepInhibitor(keepDisplayAwake: false)
        defer { guest.stop(); host.stop() }
        precondition(!guest.active && !host.active)
        try guest.setEnabled(true)
        precondition(guest.active && !host.active, "guest enabled the host assertion")
        try guest.setEnabled(true)
        try host.setEnabled(true)
        precondition(host.active && guest.active)
        let oldPID = guest.processIdentifier!
        precondition(kill(oldPID, SIGTERM) == 0)
        let deadline = Date().addingTimeInterval(4)
        while guest.processIdentifier == oldPID && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        while !guest.active && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        precondition(guest.active && guest.processIdentifier != oldPID && host.active, "caffeinate not restarted")
        try guest.setEnabled(false)
        precondition(!guest.active && host.active, "guest disabled the host assertion")
        host.stop()
        precondition(!host.active && !guest.active)
        print("PASS: independent guest/host assertions, idempotent enable, automatic caffeinate restart after termination, release on stop")
    }
}
