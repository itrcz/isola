import Foundation
@main struct HomeMirrorsSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IsolaMirrorsTest-" + UUID().uuidString)
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
        let originalACL = try command(["/bin/ls", "-lde", home.appendingPathComponent("Desktop").path]).split(separator: "\n").dropFirst().joined(separator: "\n")
        let local = home.appendingPathComponent("Desktop/local.txt")
        try Data("guest original".utf8).write(to: local)
        try Data("host file".utf8).write(to: shares.appendingPathComponent("Isola Desktop/host.txt"))
        let mirrors = HomeMirrors(home: home, shares: shares)
        try mirrors.configure(name: "Desktop", enabled: true)
        try mirrors.configure(name: "Downloads", enabled: true)
        try mirrors.configure(name: "Desktop", enabled: true) // idempotent
        let fromHost = try String(contentsOf: home.appendingPathComponent("Desktop/host.txt")); precondition(fromHost == "host file")
        try Data("guest new".utf8).write(to: home.appendingPathComponent("Downloads/new.txt"))
        let fromGuest = try String(contentsOf: shares.appendingPathComponent("Isola Downloads/new.txt")); precondition(fromGuest == "guest new")
        try fm.removeItem(at: home.appendingPathComponent("Desktop/host.txt"))
        precondition(!fm.fileExists(atPath: shares.appendingPathComponent("Isola Desktop/host.txt").path))
        try mirrors.configure(name: "Desktop", enabled: false)
        let restoredACL = try command(["/bin/ls", "-lde", home.appendingPathComponent("Desktop").path]).split(separator: "\n").dropFirst().joined(separator: "\n")
        precondition(restoredACL == originalACL, "home folder ACL changed")
        let restored = try String(contentsOf: local); precondition(restored == "guest original")
        try mirrors.configure(name: "Downloads", enabled: false)
        precondition(fm.fileExists(atPath: shares.appendingPathComponent("Isola Downloads/new.txt").path))
        _ = try command(["/bin/chmod", "-a", "group:everyone deny delete", home.appendingPathComponent("Desktop").path])
        try fm.removeItem(at: home.appendingPathComponent("Desktop"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Desktop"), withDestinationURL: root.appendingPathComponent("iCloud"))
        do { try mirrors.configure(name: "Desktop", enabled: true); fatalError("replaced foreign symlink") } catch {}
        print("PASS: shared Desktop/Downloads, bidirectional writes/deletes, local backup/restore, idempotence, foreign symlink protected, macOS home deny-delete ACL preserved")
    }
}
