import Foundation

@main struct SuspendedStateSmoke {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Isola-suspend-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = SuspendedState(folder: root)
        let record = VMRecord(networkMode: "direct", memoryGB: 4, cpus: 2, installed: true)
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("vm.json"))
        for name in ["Disk.img", "Auxiliary.bin", "Hardware.bin", "Machine.bin", "RuntimeTools.cdr"] {
            try Data(("fixture " + name).utf8).write(to: root.appendingPathComponent(name))
        }
        let originalDisk = try Data(contentsOf: root.appendingPathComponent("Disk.img"))
        let stale = Model(directory: root)
        func expectFailure(_ work: () throws -> Void) {
            do { try work(); fatalError("unsafe operation succeeded") } catch {}
        }
        func save() throws {
            let target = try store.begin()
            try Data("RAM fixture".utf8).write(to: target)
            try store.commit()
        }
        try save()
        _ = try store.validate()
        precondition(Model(directory: root).suspended)
        precondition(stale.configurationLocked, "stale UI must still block edits")
        expectFailure { try stale.persistSettings() }
        expectFailure { try stale.applyResources(cpu: 2, memory: 4, disk: 64, title: "changed") }
        expectFailure { _ = try store.begin() }
        let permissions = try fm.attributesOfItem(atPath: store.stateFile.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        // Consuming a checkpoint is irreversible before the first resumed CPU.
        try store.consume()
        precondition(store.exists && Model(directory: root).suspended)
        expectFailure { _ = try store.validate() }
        expectFailure { try stale.persistSettings() }
        try store.finishResume(); precondition(!store.exists)
        // Interrupted save is never mistaken for a clean cold boot.
        _ = try store.begin()
        precondition(store.exists && Model(directory: root).suspended)
        expectFailure { _ = try store.validate() }
        try store.cancelPreparation(); precondition(!store.exists)
        try save()
        let config = try Data(contentsOf: root.appendingPathComponent("vm.json"))
        try Data("changed config".utf8).write(to: root.appendingPathComponent("vm.json"))
        expectFailure { _ = try store.validate() }
        try store.discard()
        try config.write(to: root.appendingPathComponent("vm.json"))
        try save()
        try Data("changed disk".utf8).write(to: root.appendingPathComponent("Disk.img"))
        expectFailure { _ = try store.validate() }
        try store.discard()
        try originalDisk.write(to: root.appendingPathComponent("Disk.img"))
        try save()
        try Data("changed tools".utf8).write(to: store.tools)
        expectFailure { _ = try store.validate() }
        try store.discard()
        try save()
        try Data("truncated".utf8).write(to: store.stateFile)
        expectFailure { _ = try store.validate() }
        try store.discard()
        let finalDisk = try Data(contentsOf: root.appendingPathComponent("Disk.img"))
        precondition(finalDisk == originalDisk)
        print("PASS: atomic suspend, private state, restart discovery, stale-model guards, interrupted save/restore, modified disk/config/tools, truncated state, discard preserves disk")
    }
}
