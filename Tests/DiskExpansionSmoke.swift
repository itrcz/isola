import Foundation
@main struct DiskExpansionSmoke {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.contains("--inspect") {
            let table = try DiskExpansion.table(folder.appendingPathComponent("Disk.img"))
            print("GPT valid: sector=\(table.sector), partitions=\(table.partitions.count), recovery=\(table.recovery != nil)"); return
        }
        let bytes = CommandLine.arguments.count > 2 ? (UInt64(CommandLine.arguments[2]) ?? 2*1024*1024*1024) : 2*1024*1024*1024
        if CommandLine.arguments.contains("--fail") {
            do {
                _ = try DiskExpansion.expand(folder: folder, bytes: bytes, command: { _, _ in throw DiskExpansion.fail("Simulated attach failure") }) { _ in }
                fatalError("failure was ignored")
            } catch { print("EXPECTED FAILURE: " + error.localizedDescription); return }
        }
        let backup = try DiskExpansion.expand(folder: folder, bytes: bytes) { print($0) }
        print("PASS: relocation, APFS expansion, verification, original backup at \(backup.path)")
    }
}
