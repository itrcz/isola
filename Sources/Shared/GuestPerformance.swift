import Foundation
import AppKit

// The production preference backend is used exclusively in the guest agent.
// Tests inject an isolated store; no host accessibility settings are modified.
struct GuestPerformance {
    struct Setting { let domain: String; let key: String; let value: Any }
    static let settings: [Setting] = [
        .init(domain: "com.apple.universalaccess", key: "reduceMotion", value: true),
        .init(domain: "com.apple.universalaccess", key: "reduceTransparency", value: true),
        .init(domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", value: false),
        .init(domain: "com.apple.dock", key: "launchanim", value: false),
        .init(domain: "com.apple.dock", key: "magnification", value: false),
        .init(domain: "com.apple.dock", key: "mineffect", value: "scale"),
        .init(domain: "com.apple.dock", key: "autohide-time-modifier", value: 0.0),
        .init(domain: "com.apple.dock", key: "expose-animation-duration", value: 0.0)
    ]
    let journal: URL
    let read: (String, String) -> Any?
    let write: (String, String, Any?) throws -> Void
    let refresh: () -> Void
    init(journal: URL, read: @escaping (String, String) -> Any?, write: @escaping (String, String, Any?) throws -> Void, refresh: @escaping () -> Void = {}) {
        self.journal = journal; self.read = read; self.write = write; self.refresh = refresh
    }
    static func guest() -> GuestPerformance {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Isola Integration/visual-effects.plist")
        func domain(_ value: String) -> CFString { value == "NSGlobalDomain" ? kCFPreferencesAnyApplication : value as CFString }
        return GuestPerformance(journal: path, read: { name, key in
            CFPreferencesCopyValue(key as CFString, domain(name), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }, write: { name, key, value in
            guard FileManager.default.fileExists(atPath: "/dev/cu.org.isola.clipboard") || FileManager.default.fileExists(atPath: "/dev/tty.org.isola.clipboard") else { throw failure("Guest-only operation") }
            CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain(name), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard CFPreferencesSynchronize(domain(name), kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw failure("macOS denied access to " + name) }
            let actual = CFPreferencesCopyValue(key as CFString, domain(name), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            guard equal(actual, value) else { throw failure("macOS did not save " + key) }
        }, refresh: {
            // Restart only the guest Dock, never Finder or applications with documents.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").forEach { _ = $0.terminate() }
        })
    }
    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }; return a == b
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "Isola Performance", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func apply(_ enabled: Bool) throws {
        let fm = FileManager.default
        var saved: [[String: Any]]
        if fm.fileExists(atPath: journal.path) {
            guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: journal), format: nil) as? [[String: Any]], value.count == Self.settings.count else { throw Self.failure("Invalid visual-effects backup; settings were not changed") }
            saved = value
            for (i, setting) in Self.settings.enumerated() {
                guard saved[i]["domain"] as? String == setting.domain, saved[i]["key"] as? String == setting.key, saved[i]["present"] is Bool else { throw Self.failure("Invalid visual-effects backup") }
            }
        } else {
            if !enabled { return }
            saved = Self.settings.map { setting in
                var entry: [String: Any] = ["domain": setting.domain, "key": setting.key, "present": false]
                if let value = read(setting.domain, setting.key) { entry["present"] = true; entry["value"] = value }
                return entry
            }
            try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0).write(to: journal, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        }
        var changed = false
        do {
            for (i, setting) in Self.settings.enumerated() {
                let value: Any? = enabled ? setting.value : ((saved[i]["present"] as? Bool == true) ? saved[i]["value"] : nil)
                if !Self.equal(read(setting.domain, setting.key), value) { try write(setting.domain, setting.key, value); changed = true }
            }
            if !enabled { try fm.removeItem(at: journal) }
        } catch {
            // Retain the journal until restoration succeeds, including after a crash.
            if enabled {
                var restored = true
                for (i, setting) in Self.settings.enumerated() {
                    do { try write(setting.domain, setting.key, saved[i]["present"] as? Bool == true ? saved[i]["value"] : nil) }
                    catch { restored = false }
                }
                if restored { try? fm.removeItem(at: journal) }
            }
            if changed { refresh() }
            throw error
        }
        if changed { refresh() }
    }
}
