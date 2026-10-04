import AppKit

// Compile with -D WINDOW_LIFECYCLE_TEST and the app sources.
@main struct WindowLifecycleSmoke {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.setVolatileDomain(["vm.folder": directory.path, "library.paths": [directory.path]], forName: UserDefaults.argumentDomain)
        var lock: VMDirectoryLock? = try VMDirectoryLock(folder: directory)
        do {
            _ = try VMDirectoryLock(folder: directory)
            preconditionFailure("second session acquired the same VM")
        } catch { }
        withExtendedLifetime(lock) {}
        lock = nil
        let reopenedLock = try VMDirectoryLock(folder: directory)
        withExtendedLifetime(reopenedLock) {}
        let underlying = NSError(domain: "Restore", code: 42, userInfo: [NSLocalizedDescriptionKey: "cause"])
        let outer = NSError(domain: "VM", code: 1, userInfo: [NSUnderlyingErrorKey: underlying])
        precondition(Model.describe(outer).contains("Restore:42"))
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let original = ObjectIdentifier(delegate.window)
        precondition(!delegate.window.isReleasedWhenClosed)
        for _ in 0..<30 {
            autoreleasepool { delegate.window.close() }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            precondition(!delegate.window.isVisible)
            precondition(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
            precondition(delegate.window.isVisible)
            precondition(ObjectIdentifier(delegate.window) == original)
        }
        precondition(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true))
        delegate.window.close()
        delegate.model.cleanup()
        print("PASS: exclusive VM lock and release, nested error details, 30 close/reopen cycles, retained window identity, visible-window reopen")
        withExtendedLifetime(delegate) {}
    }
}
