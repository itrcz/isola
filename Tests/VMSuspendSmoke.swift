import AppKit
import Virtualization

// An empty sparse disk and a NEW machine identity: boots Apple firmware only,
// never a user's guest. Invoke in two separate signed processes to test restart.
@main struct VMSuspendSmoke {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("usage: save|resume fixture-folder [hardware-model-file]") }
        let root = URL(fileURLWithPath: args[2]), fm = FileManager.default
        let proxy = args.contains("--proxy")
        var fixtureLock: VMDirectoryLock?
        if args[1] == "save" {
            guard args.count >= 4, !fm.fileExists(atPath: root.path) else { fatalError("fixture must be a new directory") }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let hardwareData = try Data(contentsOf: URL(fileURLWithPath: args[3]))
            let hardware = VZMacHardwareModel(dataRepresentation: hardwareData)!
            try hardwareData.write(to: root.appendingPathComponent("Hardware.bin"))
            try VZMacMachineIdentifier().dataRepresentation.write(to: root.appendingPathComponent("Machine.bin"))
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: root.appendingPathComponent("Auxiliary.bin"), hardwareModel: hardware, options: [])
            fm.createFile(atPath: root.appendingPathComponent("Disk.img").path, contents: nil)
            let disk = try FileHandle(forWritingTo: root.appendingPathComponent("Disk.img"))
            try disk.truncate(atOffset: 64 * 1_073_741_824); try disk.close()
            let record = VMRecord(networkMode: proxy ? "proxy" : "direct", sharedFolders: [SharedFolder(path: root.path, readOnly: true, shareName: "Fixture")], syncKeyboard: false, memoryGB: 4, cpus: 2, installed: true, macAddress: VZMACAddress.randomLocallyAdministered().string, proxyHost: proxy ? "127.0.0.1" : "", proxyPort: "1", proxyUser: "", clipboard: false)
            try JSONEncoder().encode(record).write(to: root.appendingPathComponent("vm.json"))
        }
        let model = Model(directory: root)
        if args[1] == "save", proxy {
            // Offline SOCKS endpoint: exercise file-handle networking and prove
            // restore does not depend on an internet connectivity check.
            fixtureLock = try VMDirectoryLock(folder: root)
            let vm = try await model.makeMachine(); model.machine = vm
            try await vm.start(options: VZMacOSVirtualMachineStartOptions()); model.running = true
        } else {
            model.start()
            while model.busy { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard model.running else { throw AppError.message(model.error ?? "VM failed to run") }
        print("Running firmware VM (\(args[1])).")
        if args[1] == "save" {
            try await Task.sleep(for: .seconds(1))
            // A real filesystem failure after pausing must resume the live VM.
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            do { try await model.suspendMachine(); fatalError("save to read-only folder succeeded") } catch {}
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            precondition(model.running && model.machine?.state == .running && !model.savedState.exists)
            print("PASS: failed save resumes the original VM")
            model.busy = true
            try await model.suspendMachine()
            model.busy = false
            precondition(model.suspended && model.machine == nil && !model.running)
            _ = try model.savedState.validate()
            fixtureLock = nil
            model.start(recovery: true)
            while model.busy { try await Task.sleep(for: .milliseconds(50)) }
            precondition(model.machine == nil && model.suspended && model.error != nil)
            _ = try model.savedState.validate()
            print("PASS: real Virtualization pause + save + stop, filesystem/console/network configured")
        } else {
            precondition(!model.suspended && !model.savedState.exists)
            model.forceStop()
            while model.busy { try await Task.sleep(for: .milliseconds(100)) }
            precondition(model.machine == nil && !model.running)
            print("PASS: real Virtualization restore + resume in a second process")
        }
        withExtendedLifetime(fixtureLock) {}
    }
}
