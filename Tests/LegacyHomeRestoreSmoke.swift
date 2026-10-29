import Foundation
@main struct LegacyHomeRestoreSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IsolaRestoreTest-" + UUID().uuidString)
        let home = root.appendingPathComponent("Guest"), shares = root.appendingPathComponent("Shares")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        for path in [home.appendingPathComponent("Desktop"), home.appendingPathComponent("Downloads"), shares.appendingPathComponent("Isola Desktop"), shares.appendingPathComponent("Isola Downloads")] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        func command(_ args: [String]) throws -> String {
            let p = Process(), out = Pipe(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst()); p.standardOutput = out
            try p.run(); let bytes = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            precondition(p.terminationStatus == 0); return String(data: bytes, encoding: .utf8)!
        }
        for name in ["Desktop", "Downloads"] {
            _ = try command(["/bin/chmod", "+a", "group:everyone deny delete", home.appendingPathComponent(name).path])
            _ = try command(["/bin/chmod", "+a", "group:everyone allow readattr", home.appendingPathComponent(name).path])
        }
        let state = home.appendingPathComponent("Library/Application Support/Isola Integration")
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let local = home.appendingPathComponent("Desktop/local.txt")
        try Data("guest original".utf8).write(to: local)
        try Data("host original".utf8).write(to: shares.appendingPathComponent("Isola Desktop/host.txt"))
        // Recreate the on-disk journal/backup from v0.5, including its ACL.
        for name in ["Desktop", "Downloads"] {
            let folder = home.appendingPathComponent(name), target = shares.appendingPathComponent("Isola " + name)
            _ = try command(["/bin/chmod", "-a", "group:everyone deny delete", folder.path])
            let backup = state.appendingPathComponent("Local " + name)
            try fm.moveItem(at: folder, to: backup)
            _ = try command(["/bin/chmod", "+a", "group:everyone deny delete", backup.path])
            try Data(target.path.utf8).write(to: state.appendingPathComponent(name + ".json"))
            try fm.createSymbolicLink(at: folder, withDestinationURL: target)
        }
        let originalACL = try command(["/bin/ls", "-lde", state.appendingPathComponent("Local Desktop").path]).split(separator: "\n").dropFirst().joined(separator: "\n")
        let restoration = LegacyHomeRestore(home: home, shares: shares)
        // Restoration must also work when the host share is no longer mounted.
        try fm.moveItem(at: shares, to: root.appendingPathComponent("Unmounted"))
        precondition(restoration.restore() == nil)
        precondition(restoration.restore() == nil, "migration not idempotent")
        let restoredACL = try command(["/bin/ls", "-lde", home.appendingPathComponent("Desktop").path]).split(separator: "\n").dropFirst().joined(separator: "\n")
        precondition(restoredACL == originalACL, "home folder ACL changed")
        let restored = try String(contentsOf: local); precondition(restored == "guest original")
        precondition(fm.fileExists(atPath: root.appendingPathComponent("Unmounted/Isola Desktop/host.txt").path), "host data changed")
        _ = try command(["/bin/chmod", "-a", "group:everyone deny delete", home.appendingPathComponent("Desktop").path])
        try fm.removeItem(at: home.appendingPathComponent("Desktop"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Desktop"), withDestinationURL: root.appendingPathComponent("iCloud"))
        try Data(shares.appendingPathComponent("Isola Desktop").path.utf8).write(to: state.appendingPathComponent("Desktop.json"))
        precondition(restoration.restore() != nil, "replaced foreign symlink")
        let foreignLink = try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("Desktop").path)
        precondition(foreignLink == root.appendingPathComponent("iCloud").path)
        try fm.removeItem(at: home.appendingPathComponent("Desktop"))
        try fm.createDirectory(at: state.appendingPathComponent("Local Desktop"), withIntermediateDirectories: true)
        try Data("crash recovery".utf8).write(to: state.appendingPathComponent("Local Desktop/crash.txt"))
        try restoration.restore(name: "Desktop")
        precondition(fm.fileExists(atPath: home.appendingPathComponent("Desktop/crash.txt").path))
        print("PASS: old mirrors restored without mounted shares, host files untouched, idempotence, foreign links protected, interrupted migration recovered, original ACL preserved")
    }
}
