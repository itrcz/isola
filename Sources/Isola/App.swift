import SwiftUI
import AppKit
import Virtualization

struct GuestScreen: NSViewRepresentable {
    @ObservedObject var model: Model
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    @MainActor final class Coordinator {
        let model: Model
        var monitor: Any?
        weak var screen: NSView?
        var consumedSpace = false
        init(model: Model) {
            self.model = model
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyUp, event.keyCode == 49, self.consumedSpace { self.consumedSpace = false; return nil }
                guard self.model.syncKeyboard, event.window === self.screen?.window,
                      let responder = event.window?.firstResponder as? NSView, let screen = self.screen,
                      responder === screen || responder.isDescendant(of: screen),
                      event.keyCode == 49, event.type == .keyDown,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command] else { return event }
                self.consumedSpace = true
                if !event.isARepeat { self.model.switchKeyboard() }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> NSView {
        // The guest framebuffer has an intrinsic size. A neutral wrapper keeps it from
        // expanding the host window past the screen when the VM display appears.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let view = model.displayView ?? VZVirtualMachineView()
        view.virtualMachine = model.machine; view.automaticallyReconfiguresDisplay = true
        view.capturesSystemKeys = !model.hostShortcuts; model.displayView = view
        view.frame = container.bounds; view.autoresizingMask = [.width, .height]
        context.coordinator.screen = view
        container.addSubview(view); return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        if model.displayView?.virtualMachine !== model.machine { model.displayView?.virtualMachine = model.machine }
        model.displayView?.capturesSystemKeys = !model.hostShortcuts
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 480)
    }
}
struct TitlebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .titlebar; view.blendingMode = .behindWindow; view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let library = Library()
    var model: Model { library.selected }
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), root = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: L("Настройки машины…", "Machine Settings…"), action: #selector(toggleSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: L("Завершить Isola", "Quit Isola"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = app; menu.addItem(root)
        let edit = NSMenuItem(); edit.title = L("Правка", "Edit"); let submenu = NSMenu(title: edit.title)
        for (title, selector, key) in [(L("Вырезать", "Cut"), "cut:", "x"), (L("Копировать", "Copy"), "copy:", "c"), (L("Вставить", "Paste"), "paste:", "v"), (L("Выделить всё", "Select All"), "selectAll:", "a")] { submenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key) }
        edit.submenu = submenu; menu.addItem(edit); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1240,height: 820), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Isola"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.delegate = self
        window.backgroundColor = .windowBackgroundColor
        let hosting = NSHostingView(rootView: ContentView(library: library)); hosting.sizingOptions = []
        window.minSize = NSSize(width: 760, height: 520); window.contentView = hosting; window.center(); window.makeKeyAndOrderFront(nil)
        positionWindowButtons()
        NSApp.activate(ignoringOtherApps: true)
    }
    func positionWindowButtons() {
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            button.setFrameOrigin(NSPoint(x: 14 + CGFloat(index) * 20, y: parent.bounds.height - 31))
        }
    }
    @objc func toggleSettings() { model.settingsVisible.toggle() }
    func windowDidResize(_ notification: Notification) { positionWindowButtons() }
    func windowDidExitFullScreen(_ notification: Notification) { positionWindowButtons() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if library.models.contains(where: { $0.running || $0.busy }) {
            let alert = NSAlert(); alert.messageText = L("Закрыть Isola?", "Quit Isola?"); alert.informativeText = L("Работающая VM или установка будут прерваны. Лучше сначала выключить macOS из гостевой системы.", "The running VM or installation will be interrupted. Shut down guest macOS first."); alert.addButton(withTitle: L("Остаться", "Stay")); alert.addButton(withTitle: L("Закрыть", "Quit"))
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { library.models.forEach { $0.cleanup() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}
#if !WINDOW_LIFECYCLE_TEST
@main struct Launcher {
    @MainActor static func main() { let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.run(); withExtendedLifetime(delegate) {} }
}
#endif
