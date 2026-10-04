import Foundation
@main struct GuestPerformanceSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IsolaPerformanceTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var store: [String: Any] = ["com.apple.dock.mineffect": "genie", "com.apple.dock.unrelated": "keep", "com.apple.universalaccess.reduceMotion": false]
        let before = store as NSDictionary
        var refreshes = 0
        var failKey: String?
        let preferences = GuestPerformance(journal: root.appendingPathComponent("backup.plist"), read: { store[$0 + "." + $1] }, write: { domain, key, value in
            if key == failKey { failKey = nil; throw GuestPerformance.failure("simulated denied preference") }
            store[domain + "." + key] = value
        }, refresh: { refreshes += 1 })
        try preferences.apply(false); precondition(refreshes == 0 && before == store as NSDictionary)
        try preferences.apply(true)
        precondition(store["com.apple.universalaccess.reduceMotion"] as? Bool == true)
        precondition(store["com.apple.universalaccess.reduceTransparency"] as? Bool == true)
        precondition(store["com.apple.dock.mineffect"] as? String == "scale")
        try preferences.apply(true); precondition(refreshes == 1)
        try preferences.apply(false)
        precondition(before == store as NSDictionary, "original settings or absence not restored")
        precondition(!FileManager.default.fileExists(atPath: preferences.journal.path))
        failKey = "magnification"
        do { try preferences.apply(true); fatalError("failure hidden") } catch {}
        precondition(before == store as NSDictionary, "partial apply was not rolled back")
        // The journal survives agent recreation and restores exactly the same prior values.
        try preferences.apply(true)
        let restarted = GuestPerformance(journal: preferences.journal, read: { store[$0 + "." + $1] }, write: { store[$0 + "." + $1] = $2 })
        try restarted.apply(false); precondition(before == store as NSDictionary)
        print("PASS: reduced motion/transparency, Dock settings, idempotence, original/absent values restored, unrelated keys preserved, failure rollback, restart recovery")
    }
}
