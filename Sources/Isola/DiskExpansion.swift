import Foundation
import Darwin

// Only raw GPT images are accepted. All changes are made to a clone, never the live image.
enum DiskExpansion {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    static func fail(_ message: String) -> Failure { Failure(message: message) }
    struct Partition {
        var index: Int
        var type: Data
        var id: Data
        var first: UInt64
        var last: UInt64
    }
    struct Table {
        var sector: Int
        var header: Data
        var entries: Data
        var partitions: [Partition]
        var backupLBA: UInt64
        var main: Partition
        var recovery: Partition?
        var entrySectors: UInt64 { UInt64((entries.count + sector - 1) / sector) }
    }
    static func number(_ data: Data, _ offset: Int, _ length: Int = 8) -> UInt64 {
        data[offset..<(offset + length)].enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    static func put(_ data: inout Data, _ offset: Int, _ value: UInt64, _ length: Int = 8) {
        for i in 0..<length { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    static func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xedb88320) } }
        return value ^ 0xffffffff
    }
    static func read(_ file: FileHandle, _ offset: UInt64, _ count: Int) throws -> Data {
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: count), data.count == count else { throw fail("Неполный образ диска / short disk image") }
        return data
    }
    static func write(_ file: FileHandle, _ offset: UInt64, _ data: Data) throws {
        try file.seek(toOffset: offset); try file.write(contentsOf: data)
    }
    static let apfs = Data([0xef,0x57,0x34,0x7c,0,0,0xaa,0x11,0xaa,0x11,0,0x30,0x65,0x43,0xec,0xac])
    static let recoveryType = Data([0x72,0x76,0x63,0x52,0,0x79,0xaa,0x11,0xaa,0x11,0,0x30,0x65,0x43,0xec,0xac])
    static let isc = Data([0x61,0x69,0x64,0x69,0,0x67,0xaa,0x11,0xaa,0x11,0,0x30,0x65,0x43,0xec,0xac])
    static let efi = Data([0x28,0x73,0x2a,0xc1,0x1f,0xf8,0xd2,0x11,0xba,0x4b,0,0xa0,0xc9,0x3e,0xc9,0x3b])
    static func table(_ url: URL) throws -> Table {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let length = try file.seekToEnd()
        var sector = 0; var h = Data()
        for candidate in [512, 4096] {
            let data = try read(file, UInt64(candidate), candidate)
            if data.prefix(8) == Data("EFI PART".utf8) { sector = candidate; h = data; break }
        }
        guard sector > 0, length % UInt64(sector) == 0 else { throw fail("Поддерживается только raw GPT-образ с секторами 512/4096 байт.") }
        func validHeader(_ header: Data) -> Bool {
            let size = Int(number(header, 12, 4))
            guard size >= 92, size <= sector, number(header, 8, 4) == 0x10000 else { return false }
            var copy = Data(header.prefix(size)); put(&copy, 16, 0, 4)
            return UInt64(crc(copy)) == number(header, 16, 4)
        }
        let backupLBA = number(h, 32), count = number(h, 80, 4), stride = number(h, 84, 4)
        guard validHeader(h), number(h, 24) == 1, count > 0, count <= 4096, stride == 128,
              backupLBA > 2, backupLBA < length / UInt64(sector), number(h, 72) == 2,
              number(h, 40) >= 2 + (count*stride + UInt64(sector)-1)/UInt64(sector),
              backupLBA > (count*stride + UInt64(sector)-1)/UInt64(sector)+1,
              number(h, 48) <= backupLBA-(count*stride + UInt64(sector)-1)/UInt64(sector)-1 else { throw fail("Некорректная GPT. Исходный диск не изменён.") }
        let entries = try read(file, 2 * UInt64(sector), Int(count * stride))
        let backup = try read(file, backupLBA * UInt64(sector), sector)
        guard validHeader(backup), number(backup, 24) == backupLBA, number(backup, 32) == 1,
              backup[56..<72] == h[56..<72], number(backup, 80, 4) == count, number(backup, 84, 4) == stride,
              number(backup, 72) == backupLBA-(count*stride + UInt64(sector)-1)/UInt64(sector), UInt64(crc(entries)) == number(h, 88, 4), number(backup, 88, 4) == number(h, 88, 4),
              try read(file, number(backup, 72) * UInt64(sector), entries.count) == entries else { throw fail("Основная и резервная GPT не совпадают. Нужна диагностика диска.") }
        var parts = [Partition]()
        for i in 0..<Int(count) {
            let base = i * 128, type = Data(entries[base..<(base + 16)])
            if type.allSatisfy({ $0 == 0 }) { continue }
            let p = Partition(index: i, type: type, id: Data(entries[(base+16)..<(base+32)]), first: number(entries, base+32), last: number(entries, base+40))
            guard p.first >= number(h, 40), p.last <= number(h, 48), p.first <= p.last else { throw fail("Раздел выходит за границы GPT.") }
            parts.append(p)
        }
        parts.sort { $0.first < $1.first }
        guard zip(parts, parts.dropFirst()).allSatisfy({ $0.last < $1.first }), Set(parts.map(\.id)).count == parts.count,
              parts.filter({ $0.type == apfs }).count == 1, let main = parts.first(where: { $0.type == apfs }),
              parts.filter({ $0.type == recoveryType }).count <= 1,
              parts.allSatisfy({ [apfs, recoveryType, isc, efi].contains($0.type) }),
              parts.filter({ $0.first < main.first }).allSatisfy({ $0.type == isc || $0.type == efi }),
              parts.filter({ $0.first > main.first }).allSatisfy({ $0.type == recoveryType }) else { throw fail("Нестандартная разметка: автоматическое расширение остановлено.") }
        let recovery = parts.first { $0.type == recoveryType }
        for p in [main, recovery].compactMap({ $0 }) {
            let superblock = try read(file, p.first * UInt64(sector), 4096)
            guard superblock[32..<36] == Data("NXSB".utf8) else { throw fail("Раздел не содержит ожидаемый APFS-контейнер.") }
        }
        return Table(sector: sector, header: h, entries: entries, partitions: parts, backupLBA: backupLBA, main: main, recovery: recovery)
    }
    // Caller supplies a separate clone; reading from the original also handles overlapping moves.
    static func relocate(source: URL, copy: URL, bytes: UInt64) throws -> Table {
        var t = try table(source)
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        guard bytes >= (try input.seekToEnd()), bytes % UInt64(t.sector) == 0 else { throw fail("Уменьшение диска запрещено.") }
        let output = try FileHandle(forUpdating: copy); defer { try? output.close() }
        try output.truncate(atOffset: bytes)
        let lastLBA = bytes / UInt64(t.sector) - 1, lastUsable = lastLBA - t.entrySectors - 1
        if let recovery = t.recovery {
            let size = recovery.last - recovery.first + 1
            // Preserve 4 KiB alignment; reserve the GPT table at the end.
            let alignment = UInt64(4096 / t.sector)
            let first = (lastUsable + 1 - size) / alignment * alignment
            guard first >= recovery.first else { throw fail("Недостаточно места для переноса Recovery.") }
            if first != recovery.first {
                var offset: UInt64 = 0
                let total = size * UInt64(t.sector)
                while offset < total {
                    let chunk = try read(input, recovery.first * UInt64(t.sector) + offset, Int(min(4*1024*1024, total-offset)))
                    try write(output, first * UInt64(t.sector) + offset, chunk)
                    offset += UInt64(chunk.count)
                }
                try output.synchronize()
                // Verify byte-for-byte before updating either partition table.
                offset = 0
                while offset < total {
                    let count = Int(min(4*1024*1024, total-offset))
                    guard try read(input, recovery.first * UInt64(t.sector)+offset, count) == read(output, first * UInt64(t.sector)+offset, count) else { throw fail("Проверка копии Recovery не прошла.") }
                    offset += UInt64(count)
                }
                put(&t.entries, recovery.index * 128 + 32, first)
                put(&t.entries, recovery.index * 128 + 40, first + size - 1)
            }
        }
        put(&t.header, 32, lastLBA); put(&t.header, 48, lastUsable)
        put(&t.header, 88, UInt64(crc(t.entries)), 4)
        func header(_ lba: UInt64, _ other: UInt64, _ entries: UInt64) -> Data {
            var h = t.header; put(&h, 24, lba); put(&h, 32, other); put(&h, 72, entries); put(&h, 16, 0, 4)
            put(&h, 16, UInt64(crc(Data(h.prefix(Int(number(h,12,4)))))), 4); return h
        }
        try write(output, (lastLBA-t.entrySectors)*UInt64(t.sector), t.entries)
        try write(output, lastLBA*UInt64(t.sector), header(lastLBA, 1, lastLBA-t.entrySectors))
        try write(output, 2*UInt64(t.sector), t.entries)
        try write(output, UInt64(t.sector), header(1, lastLBA, 2))
        var mbr = try read(input, 0, t.sector)
        guard mbr[510] == 0x55, mbr[511] == 0xaa, mbr[450] == 0xee,
              [462,478,494].allSatisfy({ mbr[$0+4] == 0 }) else { throw fail("Гибридный MBR не поддерживается.") }
        put(&mbr, 458, min(lastLBA, UInt64(UInt32.max)), 4); try write(output, 0, mbr)
        try output.synchronize()
        return try table(copy)
    }
    static func run(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process(), out = Pipe()
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("isola-disk-error-" + UUID().uuidString)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let errors = try FileHandle(forUpdating: errorURL)
        defer { try? errors.close(); try? FileManager.default.removeItem(at: errorURL) }
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = errors
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try errors.seek(toOffset: 0)
            let detail = (String(data: data.suffix(4000), encoding: .utf8) ?? "") + (String(data: (try errors.read(upToCount: 4000)) ?? Data(), encoding: .utf8) ?? "")
            throw fail("\(URL(fileURLWithPath: path).lastPathComponent): " + detail)
        }
        return data
    }
    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw fail("Некорректный ответ дисковой утилиты.") }; return value
    }
    // Returns a full pre-change VM backup. The UI keeps it until the user removes it.
    static func expand(folder: URL, bytes: UInt64, command: (String, [String]) throws -> Data = DiskExpansion.run, progress: (String) -> Void) throws -> URL {
        let fm = FileManager.default, disk = folder.appendingPathComponent("Disk.img")
        let original = try table(disk)
        let attributes = try disk.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw fail("Нужен обычный файл Disk.img.") }
        // Clone-on-write prevents a full extra allocation of a potentially huge sparse disk.
        let backup = folder.appendingPathComponent("Before expansion " + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let savedDisk = backup.appendingPathComponent("Disk.img"), work = folder.appendingPathComponent(".expanding-" + UUID().uuidString + ".img")
        guard clonefile(disk.path, savedDisk.path, 0) == 0 else { try? fm.removeItem(at: backup); throw fail("Для безопасного расширения нужен том APFS с поддержкой clonefile. Исходный диск не изменён.") }
        for name in ["vm.json", "Auxiliary.bin", "Hardware.bin", "Machine.bin"] {
            let source = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: backup.appendingPathComponent(name)) }
        }
        guard clonefile(disk.path, work.path, 0) == 0 else { throw fail("Не удалось создать рабочую копию. Резервная копия: " + backup.path) }
        var attached: String?
        defer {
            if let device = attached { _ = try? command("/usr/bin/hdiutil", ["detach", device]) }
            if attached == nil { try? fm.removeItem(at: work) }
        }
        progress("Сохранена резервная копия. Перенос Recovery…")
        let moved = try relocate(source: savedDisk, copy: work, bytes: bytes)
        let end = (moved.recovery?.first ?? (bytes / UInt64(moved.sector) - moved.entrySectors - 1))
        guard end > moved.main.last + 2048 else { throw fail("Для основного контейнера нет нового свободного места.") }
        progress("Расширение основного APFS-контейнера…")
        let info = try dictionary(command("/usr/bin/hdiutil", ["attach", "-nomount", "-noverify", "-noautofsck", "-imagekey", "diskimage-class=CRawDiskImage", work.path, "-plist"]))
        guard let entities = info["system-entities"] as? [[String: Any]], let device = entities.compactMap({ $0["dev-entry"] as? String }).first(where: { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil }) else { throw fail("Не удалось определить подключённый тестовый образ.") }
        attached = device
        let partition = device + "s" + String(moved.main.index + 1)
        _ = try command("/usr/sbin/diskutil", ["apfs", "resizeContainer", partition, "0"])
        _ = try command("/usr/sbin/diskutil", ["verifyVolume", partition])
        _ = try command("/usr/bin/hdiutil", ["detach", device]); attached = nil
        let finished = try table(work)
        guard finished.main.id == original.main.id, finished.main.first == original.main.first,
              finished.main.last > original.main.last,
              finished.recovery?.id == original.recovery?.id,
              end > finished.main.last, finished.partitions.count == moved.partitions.count,
              finished.recovery?.first == moved.recovery?.first, finished.recovery?.last == moved.recovery?.last,
              end - finished.main.last < UInt64(8*1024*1024 / finished.sector) else { throw fail("Проверка нового размера APFS не прошла. Исходный диск сохранён.") }
        let f = try FileHandle(forReadingFrom: work); defer { try? f.close() }
        let sb = try read(f, finished.main.first*UInt64(finished.sector), 4096)
        let fsSize = number(sb,40)*number(sb,36,4)
        let partitionSize = (finished.main.last-finished.main.first+1)*UInt64(finished.sector)
        guard fsSize <= partitionSize, partitionSize-fsSize < 8*1024*1024 else { throw fail("APFS не использует новый размер. Исходный диск сохранён.") }
        progress("Проверки завершены. Замена образа…")
        guard rename(work.path, disk.path) == 0 else { throw fail("Не удалось заменить Disk.img. Резервная копия: " + backup.path) }
        return backup
    }
}
