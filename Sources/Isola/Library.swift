import AppKit
import SwiftUI

@MainActor final class Library: ObservableObject {
    @Published var models: [Model]
    @Published var selection: String = ""
    var selected: Model { models.first { $0.folder.path == selection } ?? models[0] }
    init() {
        let first = Model()
        let paths = UserDefaults.standard.stringArray(forKey: "library.paths") ?? [first.folder.path]
        var seen = Set<String>()
        models = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }.map { Model(directory: $0) }
        if models.isEmpty { models = [first] }
        selection = UserDefaults.standard.string(forKey: "library.selected") ?? models[0].folder.path
        if !models.contains(where: { $0.folder.path == selection }) { selection = models[0].folder.path }
    }
    func select(_ model: Model) { selection = model.folder.path; persist() }
    func persist() {
        UserDefaults.standard.set(models.map { $0.folder.path }, forKey: "library.paths")
        UserDefaults.standard.set(selection, forKey: "library.selected")
    }
    func add(existing: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = !existing
        panel.message = existing ? L("Выберите папку существующей VM", "Choose an existing VM folder") : L("Создайте отдельную пустую папку для новой VM", "Create a separate empty folder for the new VM")
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL.resolvingSymlinksInPath() else { return }
        if let model = models.first(where: { $0.folder == url }) { select(model); return }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if existing ? !files.contains("vm.json") : !files.filter({ !$0.hasPrefix(".") }).isEmpty {
            let alert = NSAlert(); alert.messageText = existing ? L("В папке нет vm.json", "This folder has no vm.json") : L("Нужна пустая папка", "Choose an empty folder"); alert.runModal(); return
        }
        let model = Model(directory: url); models.append(model); select(model)
    }
    func removeSelected() {
        guard models.count > 1, !selected.running, !selected.busy else { return }
        models.removeAll { $0.folder.path == selection }; selection = models[0].folder.path; persist()
    }
    func start(_ model: Model, install: Bool = false, recovery: Bool = false) {
        // Only one active guest can own the shared host clipboard and resource budget.
        guard !models.contains(where: { $0 !== model && ($0.machine != nil || $0.busy) }) else {
            model.error = L("Сначала выключите другую VM. Одновременно работает одна машина.", "Shut down the other VM first. One machine can run at a time."); return
        }
        if install { model.install() } else { model.start(recovery: recovery) }
    }
}
