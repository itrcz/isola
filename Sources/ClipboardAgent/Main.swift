import AppKit
import Darwin

@main struct ClipboardAgent {
    static let portPath = "/dev/cu.org.isola.clipboard"
    @MainActor static func main() {
        // Without the Isola virtual port, never install or read a host clipboard accidentally.
        guard FileManager.default.fileExists(atPath: portPath) || FileManager.default.fileExists(atPath: "/dev/tty.org.isola.clipboard") else {
            fputs("Запускай помощник внутри macOS в Isola с включённым общим буфером.\n", stderr); exit(1)
        }
        if CommandLine.arguments.contains("--install") { install(); return }
        if CommandLine.arguments.contains("--uninstall") { uninstall(); return }
        signal(SIGPIPE, SIG_IGN)
        let path = FileManager.default.fileExists(atPath: portPath) ? portPath : "/dev/tty.org.isola.clipboard"
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { fputs("Не удалось открыть порт буфера обмена.\n", stderr); exit(1) }
        var settings = termios()
        if tcgetattr(fd, &settings) == 0 { cfmakeraw(&settings); settings.c_cflag |= tcflag_t(CLOCAL | CREAD); _ = tcsetattr(fd, TCSANOW, &settings) }
        let endpoint = ClipboardEndpoint(fd: fd, host: false)
        let performance = GuestPerformance.guest()
        endpoint.onPerformance = { try performance.apply($0) }
        let sleep = SleepInhibitor(keepDisplayAwake: true)
        endpoint.onPreventSleep = { try sleep.setEnabled($0) }
        sleep.onError = { endpoint.reportSleepError($0) }
        let cursor = GuestRemoteCursor()
        endpoint.onRemoteCursor = { cursor.setEnabled($0) }
        cursor.send = { endpoint.publishCursor($0) }
        let restoration = LegacyHomeRestore()
        var restoreError = restoration.restore()
        endpoint.start()
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in
            if endpoint.closed { cursor.stop(); sleep.stop(); exit(1) }
            if restoreError != nil {
                restoreError = restoration.restore()
                endpoint.reportStatus(restoreError ?? L("Локальные папки гостя восстановлены.", "Local guest folders restored."))
            }
        } }
        app.run(); cursor.stop(); sleep.stop(); withExtendedLifetime((endpoint, monitor, sleep, cursor)) {}
    }
    static var destination: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Isola Clipboard/isola-clipboard") }
    static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.isola.clipboard.plist") }
    @discardableResult static func launchctl(_ arguments: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
    static func install() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            launchctl(["bootout", "gui/\(getuid())/local.isola.clipboard"])
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))
            try data.write(to: destination, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            let config: [String: Any] = ["Label": "local.isola.clipboard", "ProgramArguments": [destination.path], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5, "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive"]
            try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: plist, options: .atomic)
            guard launchctl(["bootstrap", "gui/\(getuid())", plist.path]) == 0 else { throw NSError(domain: "Isola", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить LaunchAgent."]) }
            print("Общий буфер установлен. Копируй текст, изображение или файлы на одной стороне и вставляй на другой. Раскладка синхронизируется, если включена в Isola. Можно закрыть это окно.")
        } catch { fputs("Ошибка установки: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func uninstall() {
        launchctl(["bootout", "gui/\(getuid())/local.isola.clipboard"])
        if let error = LegacyHomeRestore().restore() { fputs(error + "\n", stderr) }
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: destination)
        print("Помощник буфера обмена удалён из гостевой macOS.")
    }
}
