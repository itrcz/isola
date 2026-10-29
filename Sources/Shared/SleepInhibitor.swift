import Foundation

// Use the same command as the user's working manual workaround. Remember the
// requested state and repair an exited child, without changing OS preferences.
@MainActor final class SleepInhibitor {
    private var process: Process?
    private var timer: Timer?
    private var enabled = false
    private let flags: String
    var onError: ((String) -> Void)?
    init(keepDisplayAwake: Bool) { flags = keepDisplayAwake ? "-dis" : "-is" }
    var active: Bool { process?.isRunning == true }
    var processIdentifier: Int32? { active ? process?.processIdentifier : nil }
    func setEnabled(_ enabled: Bool) throws {
        if !enabled { stop(); return }
        self.enabled = true
        try refresh()
        if timer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
                do { try self?.refresh() } catch { self?.onError?(error.localizedDescription) }
            } }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    func refresh() throws {
        guard enabled, !active else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        child.arguments = [flags, "-w", String(ProcessInfo.processInfo.processIdentifier)]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); process = child
    }
    func stop() {
        enabled = false; timer?.invalidate(); timer = nil
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        process = nil
    }
    deinit { timer?.invalidate(); if let process, process.isRunning { process.terminate() } }
}
