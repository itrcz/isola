import Foundation
import CryptoKit
import Darwin

// The state file contains memory/devices, not a disk snapshot. Never replay it
// after the attached disk or VM identity has changed. All mutations require the
// caller's VMDirectoryLock. Incomplete transactions block a normal boot too.
struct SuspendedState {
    struct FileStamp: Codable, Equatable {
        let size: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let digest: String?
        static func read(_ url: URL, hash: Bool) throws -> Self {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw AppError.message(L("Не найден обычный файл VM: ", "VM file is missing or is not a regular file: ") + url.lastPathComponent)
            }
            return Self(size: UInt64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                        modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                        digest: hash ? SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() : nil)
        }
    }
    struct Manifest: Codable {
        var version = 1
        var date = Date()
        var files: [String: FileStamp]
        var state: FileStamp
    }
    let folder: URL
    var committed: URL { folder.appendingPathComponent("Suspended.vmstate", isDirectory: true) }
    var preparing: URL { folder.appendingPathComponent(".suspend-preparing", isDirectory: true) }
    var consuming: URL { folder.appendingPathComponent(".resume-in-progress", isDirectory: true) }
    var tools: URL { folder.appendingPathComponent("RuntimeTools.cdr") }
    var exists: Bool { [committed, preparing, consuming].contains { FileManager.default.fileExists(atPath: $0.path) } }
    var stateFile: URL { committed.appendingPathComponent("State.bin") }
    private let tracked = ["vm.json", "Hardware.bin", "Machine.bin", "Auxiliary.bin", "Disk.img", "RuntimeTools.cdr"]

    func begin() throws -> URL {
        guard !exists else { throw AppError.message(L("У VM уже есть сохранённое или незавершённое состояние.", "The VM already has saved or unfinished state.")) }
        try FileManager.default.createDirectory(at: preparing, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return preparing.appendingPathComponent("State.bin")
    }
    func stamps() throws -> [String: FileStamp] {
        try Dictionary(uniqueKeysWithValues: tracked.map { ($0, try FileStamp.read(folder.appendingPathComponent($0), hash: $0 != "Disk.img")) })
    }
    func commit() throws {
        let state = preparing.appendingPathComponent("State.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
        try Self.sync(state)
        for name in tracked { try Self.sync(folder.appendingPathComponent(name)) }
        let manifest = Manifest(files: try stamps(), state: try FileStamp.read(state, hash: false))
        try write(manifest, in: preparing)
        try FileManager.default.moveItem(at: preparing, to: committed)
        try Self.sync(folder)
    }
    // Virtualization may flush auxiliary storage while stopping the paused VM.
    func finishStopping() throws {
        var manifest = try readManifest()
        manifest.files = try stamps()
        try write(manifest, in: committed)
    }
    func validate() throws -> Manifest {
        guard !FileManager.default.fileExists(atPath: consuming.path), !FileManager.default.fileExists(atPath: preparing.path) else {
            throw AppError.message(L("Сохранение или восстановление было прервано. Повторный запуск старой памяти небезопасен. Удали сохранённое состояние для обычного запуска.", "Saving or restoring was interrupted. Replaying old memory is unsafe. Discard the saved state to boot normally."))
        }
        let manifest = try readManifest()
        guard manifest.version == 1, manifest.files == (try stamps()), manifest.state == (try FileStamp.read(stateFile, hash: false)) else {
            throw AppError.message(L("Файлы или настройки VM изменились после паузы. Продолжить это состояние нельзя; можно удалить его и загрузить macOS заново.", "VM files or settings changed after suspension. Discard the saved state to boot macOS again."))
        }
        return manifest
    }
    func readManifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: committed.appendingPathComponent("Manifest.json")))
    }
    // Commit consumption BEFORE any guest CPU can write to the disk. A crash
    // after this point must not offer the old RAM image for another restore.
    func consume() throws {
        try FileManager.default.moveItem(at: committed, to: consuming)
        try Self.sync(folder)
    }
    func finishResume() throws {
        try FileManager.default.removeItem(at: consuming)
        try Self.sync(folder)
    }
    func cancelPreparation() throws {
        if FileManager.default.fileExists(atPath: preparing.path) { try FileManager.default.removeItem(at: preparing) }
    }
    func discard() throws {
        for url in [committed, preparing, consuming] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try Self.sync(folder)
    }
    private func write(_ manifest: Manifest, in directory: URL) throws {
        let url = directory.appendingPathComponent("Manifest.json")
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.sync(url); try Self.sync(directory)
    }
    static func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
