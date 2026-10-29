import Foundation
import Darwin

// Migration only: restore folders created by Isola <= 0.5. No new mirrors.
// Never move, copy or delete anything in the host share.
struct LegacyHomeRestore {
    let home: URL
    let shares: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         shares: URL = URL(fileURLWithPath: "/Volumes/My Shared Files")) { self.home = home; self.shares = shares }
    private var state: URL { home.appendingPathComponent("Library/Application Support/Isola Integration") }
    func restore() -> String? {
        var errors: [String] = []
        for name in ["Desktop", "Downloads"] {
            do { try restore(name: name) }
            catch { errors.append(name + ": " + error.localizedDescription) }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
    func restore(name: String) throws {
        guard ["Desktop", "Downloads"].contains(name) else { throw failure("Unknown folder") }
        let fm = FileManager.default, local = home.appendingPathComponent(name)
        let target = shares.appendingPathComponent("Isola " + name)
        let backup = state.appendingPathComponent("Local " + name)
        let marker = state.appendingPathComponent(name + ".json")
        guard fm.fileExists(atPath: marker.path) else { return }
        guard (try? Data(contentsOf: marker)) == Data(target.path.utf8) else {
            throw failure("Неизвестная запись восстановления. Файлы оставлены на месте.")
        }
        let link = try? fm.destinationOfSymbolicLink(atPath: local.path)
        guard link == target.path || (link == nil && !fm.fileExists(atPath: local.path)) else {
            throw failure("Локальная папка уже заменена. Прежние файлы сохранены в " + backup.path)
        }
        let hasBackup = fm.fileExists(atPath: backup.path)
        if hasBackup {
            let values = try backup.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw failure("Некорректная резервная папка.") }
        }
        if link != nil { try fm.removeItem(at: local) }
        do {
            if hasBackup { try moveHomeFolder(from: backup, to: local) }
            else { try fm.createDirectory(at: local, withIntermediateDirectories: false) }
            try fm.removeItem(at: marker)
        } catch {
            if link != nil, !fm.fileExists(atPath: local.path) { try? fm.createSymbolicLink(at: local, withDestinationURL: target) }
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
    private func failure(_ text: String) -> NSError { NSError(domain: "Isola Folder Restore", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
