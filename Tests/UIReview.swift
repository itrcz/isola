import AppKit
import SwiftUI

// An isolated visual-review window: no VM disks or user settings are opened for writing.
// Build using scripts/preview_ui.sh. It deliberately does not start a guest.
@main struct UIReview {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Isola-UI-Review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.setVolatileDomain(["vm.folder": directory.path, "library.paths": [directory.path], "library.selected": directory.path, "AppleLanguages": arguments.contains("--ru") ? ["ru"] : ["en"]], forName: UserDefaults.argumentDomain)
        let model = Model(directory: directory)
        model.name = arguments.contains("--long-name") ? "Рабочая macOS для разработки" : "macOS"
        model.installed = !arguments.contains("--setup")
        model.networkMode = "direct"
        model.cpus = 4; model.memoryGB = 8; model.diskGB = 80
        model.settingsVisible = !arguments.contains("--welcome")
        model.settingsSection = arguments.contains("--integration") ? 2 : arguments.contains("--network") ? 1 : 0
        if arguments.contains("--proxy") { model.networkMode = "proxy" }
        model.integrationStatus = L("Помощник подключится после запуска macOS.", "Tools will connect when macOS starts.")
        if arguments.contains("--error") { model.error = L("Не удалось подключиться к прокси. Проверь адрес сервера и порт.", "Could not connect to the proxy. Check the server address and port.") }
        if arguments.contains("--suspended") {
            try model.saveRecord(installed: true)
            try FileManager.default.createDirectory(at: model.savedState.committed, withIntermediateDirectories: true)
            model.reload()
        }
        let library = Library(); library.models = [model]; library.selection = model.folder.path
        if arguments.contains("--tabs") {
            for name in ["Development", "Testing", "macOS Sequoia", "Work"] {
                let other = Model(directory: directory.appendingPathComponent(name)); other.name = name; other.installed = true
                library.models.append(other)
            }
        }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: arguments.contains("--light") ? .aqua : .darkAqua)
        app.finishLaunching()
        let menu = NSMenu(); let root = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit UI Review", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu; menu.addItem(root); app.mainMenu = menu
        let compact = arguments.contains("--compact")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: compact ? 800 : 1240, height: compact ? 600 : 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Isola · UI Review"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.backgroundColor = .windowBackgroundColor
        let hosting = NSHostingView(rootView: ContentView(library: library)); hosting.sizingOptions = []
        window.minSize = NSSize(width: 760, height: 520); window.contentView = hosting
        window.center(); window.makeKeyAndOrderFront(nil)
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            if let button = window.standardWindowButton(kind), let parent = button.superview {
                button.setFrameOrigin(NSPoint(x: 14 + CGFloat(index) * 20, y: parent.bounds.height - 31))
            }
        }
        app.activate(ignoringOtherApps: true); app.run(); withExtendedLifetime(window) {}
    }
}
