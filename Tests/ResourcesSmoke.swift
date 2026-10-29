import AppKit

@main struct ResourcesSmoke {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Isola-resources-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A sparse fixture, never a real user disk.
        let disk = root.appendingPathComponent("Disk.img")
        let sentinel = Data("ISOLA-KEEP-DATA".utf8)
        FileManager.default.createFile(atPath: disk.path, contents: sentinel)
        let handle = try FileHandle(forWritingTo: disk); try handle.truncate(atOffset: 64 * 1_073_741_824); try handle.close()
        let legacy = VMRecord(memoryGB: 6, cpus: 4, installed: true, macAddress: "02:49:53:00:00:04")
        try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("vm.json"))
        let model = Model(directory: root)
        let testCPUs = min(6, Model.maximumCPUs), testMemory = min(8, Model.maximumMemoryGB)
        precondition(model.installed && model.host.isEmpty && model.hostShortcuts)
        try model.applyResources(cpu: testCPUs, memory: testMemory, disk: 64, title: "Test Mac")
        precondition(model.actualDiskGB == 64 && !model.diskExpansionPending)
        let read = try FileHandle(forReadingFrom: disk); let bytes = try read.read(upToCount: sentinel.count); precondition(bytes == sentinel); try read.close()
        let reloaded = Model(directory: root)
        precondition(reloaded.cpus == testCPUs && reloaded.memoryGB == testMemory && reloaded.diskGB == 64 && reloaded.name == "Test Mac")
        do { try model.applyResources(cpu: testCPUs, memory: testMemory, disk: 63, title: "bad"); fatalError("shrink allowed") } catch {}
        precondition(model.actualDiskGB == 64 && model.name == "Test Mac")
        do { try model.applyResources(cpu: 1, memory: testMemory, disk: 80, title: "bad"); fatalError("invalid CPU allowed") } catch {}
        precondition(!model.optimizePerformance)
        precondition(model.networkMode == "proxy" && model.sharedFolders.isEmpty && model.syncKeyboard)
        model.networkMode = "direct"; model.directRules = "*company.com\n10.0.0.0/8"
        model.optimizePerformance = true; model.preventGuestSleep = true; model.preventHostSleep = false
        model.sharedFolders = [SharedFolder(path: root.path, readOnly: false)]; model.syncKeyboard = false
        try model.persistSettings()
        let integration = Model(directory: root)
        precondition(integration.networkMode == "direct" && integration.directRules == model.directRules)
        precondition(integration.optimizePerformance)
        precondition(integration.preventGuestSleep && !integration.preventHostSleep)
        precondition(integration.sharedFolders[0].shareName != nil)
        precondition(integration.sharedFolders.count == 1 && !integration.sharedFolders[0].readOnly && !integration.syncKeyboard)
        let shareRoot = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
        let first = SharedFolder(path: root.path, shareName: "First")
        let second = SharedFolder(path: shareRoot.path, readOnly: false, shareName: "Second")
        integration.updateSharedFolders([first, second])
        do { _ = try Model.directoryShare([SharedFolder(path: root.path, shareName: "..")]); fatalError("unsafe share name accepted") } catch {}
        do { _ = try Model.directoryShare([SharedFolder(path: root.path, shareName: String(repeating: "a", count: 256))]); fatalError("oversized share name accepted") } catch {}
        let share = try Model.directoryShare(integration.sharedFolders)
        precondition(share.directories["First"]?.isReadOnly == true && share.directories["Second"]?.isReadOnly == false)
        integration.updateSharedFolders([second])
        precondition(Model(directory: root).sharedFolders[0].mountName == "Second", "mount renamed after deleting another share")
        let saved = try Data(contentsOf: root.appendingPathComponent("vm.json"))
        integration.updateSharedFolders([SharedFolder(path: root.appendingPathComponent("missing").path, shareName: "Bad")])
        precondition(integration.sharedFolders.count == 1 && integration.sharedFolders[0].id == second.id)
        let unchanged = try Data(contentsOf: root.appendingPathComponent("vm.json"))
        precondition(saved == unchanged, "failed folder update corrupted saved settings")
        let json = try JSONSerialization.jsonObject(with: unchanged) as! [String: Any]
        precondition(json["mirrorDesktop"] == nil && json["mirrorDownloads"] == nil)
        let lock = try VMDirectoryLock(folder: root)
        do { try model.applyResources(cpu: testCPUs, memory: testMemory, disk: 96, title: "bad"); fatalError("locked resize allowed") } catch {}
        withExtendedLifetime(lock) {}
        precondition(model.actualDiskGB == 64)
        print("PASS: legacy migration, per-VM settings, metadata saves preserve disk bytes, shrink/resource validation, lock excludes resize")
    }
}
