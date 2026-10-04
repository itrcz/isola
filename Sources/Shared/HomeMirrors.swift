import Foundation
import Darwin

// Invoked only by the guest agent, after receiving the host's explicit configuration.
// Fixed paths only; the protocol cannot request arbitrary filesystem operations.
struct HomeMirrors {
    let home: URL
    let shares: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         shares: URL = URL(fileURLWithPath: "/Volumes/My Shared Files")) { self.home = home; self.shares = shares }
    private var state: URL { home.appendingPathComponent("Library/Application Support/Isola Integration") }
    func apply(desktop: Bool, downloads: Bool) -> String {
        var results = [String]()
        for (name, enabled) in [("Desktop", desktop), ("Downloads", downloads)] {
            do { try configure(name: name, enabled: enabled); if enabled { results.append(name + ": общая папка подключена") } }
            catch { results.append(name + ": " + error.localizedDescription) }
        }
        return results.isEmpty ? "Isola Tools подключён" : results.joined(separator: "\n")
    }
    func configure(name: String, enabled: Bool) throws {
        guard ["Desktop", "Downloads"].contains(name) else { throw failure("Unknown mirror") }
        let fm = FileManager.default, local = home.appendingPathComponent(name)
        let target = shares.appendingPathComponent("Isola " + name)
        let backup = state.appendingPathComponent("Local " + name)
        let marker = state.appendingPathComponent(name + ".json")
        let link = try? fm.destinationOfSymbolicLink(atPath: local.path)
        if !enabled {
            guard fm.fileExists(atPath: marker.path) else { return }
            if link == nil && !fm.fileExists(atPath: local.path) && fm.fileExists(atPath: backup.path) {
                try moveHomeFolder(from: backup, to: local); try? fm.removeItem(at: marker); return
            }
            guard link == target.path else { return }
            try fm.removeItem(at: local)
            do {
                if fm.fileExists(atPath: backup.path) { try moveHomeFolder(from: backup, to: local) }
                else { try fm.createDirectory(at: local, withIntermediateDirectories: false) }
                try? fm.removeItem(at: marker)
            } catch { try? fm.createSymbolicLink(at: local, withDestinationURL: target); throw error }
            return
        }
        let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
        guard values.isDirectory == true, values.isWritable == true else { throw failure("Ожидание общей папки. Перезапустите VM с включённой интеграцией.") }
        if link == target.path { return }
        guard link == nil else { throw failure("Уже используется другая ссылка, в том числе iCloud. Папка не изменена.") }
        try fm.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: local.path) {
            guard !fm.fileExists(atPath: backup.path) else { throw failure("Сохранена прежняя локальная папка: " + backup.path + ". Автоматическая замена остановлена.") }
            // Journal first: after a crash, a moved folder can always be restored.
            try Data(target.path.utf8).write(to: marker, options: .atomic)
            try moveHomeFolder(from: local, to: backup)
        } else if !fm.fileExists(atPath: marker.path) {
            try Data(target.path.utf8).write(to: marker, options: .atomic)
        }
        do { try fm.createSymbolicLink(at: local, withDestinationURL: target) }
        catch {
            if fm.fileExists(atPath: backup.path) { try? moveHomeFolder(from: backup, to: local) }
            throw error
        }
    }
    // Apple's standard home folders carry an everyone-deny-delete ACE. Rename
    // requires temporarily removing that exact ACE, not clearing the full ACL.
    private func moveHomeFolder(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        do { try fm.moveItem(at: source, to: destination); return }
        catch {
            let originalError = error
            let fd = Darwin.open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw originalError }
            defer { Darwin.close(fd) }
            guard let originalACL = acl_get_fd(fd) else { throw originalError }
            defer { acl_free(UnsafeMutableRawPointer(originalACL)) }
            guard let text = acl_to_text(originalACL, nil) else { throw originalError }
            let aclText = String(cString: text); acl_free(text)
            let protectedEntry = "group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete"
            guard aclText.components(separatedBy: .newlines).contains(protectedEntry) else { throw originalError }
            let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-a", "group:everyone deny delete", source.path]
            chmod.standardOutput = FileHandle.nullDevice; chmod.standardError = FileHandle.nullDevice
            try chmod.run(); chmod.waitUntilExit()
            guard chmod.terminationStatus == 0 else { throw originalError }
            do { try fm.moveItem(at: source, to: destination) }
            catch {
                let restored = acl_set_fd(fd, originalACL)
                if restored != 0 { throw failure("Не удалось восстановить права: " + source.path) }
                throw error
            }
            guard acl_set_fd(fd, originalACL) == 0 else {
                // Roll back a rename if its original protection could not be restored.
                try? fm.moveItem(at: destination, to: source)
                _ = acl_set_fd(fd, originalACL)
                throw failure("Перенос отменён: не удалось восстановить исходные права папки.")
            }
        }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "Isola Home Mirrors", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
