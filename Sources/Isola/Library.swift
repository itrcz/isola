import AppKit
import SwiftUI

@MainActor final class Library: ObservableObject {
    @Published var models: [Model]
    @Published var selection: String = ""
    @Published var remote: RemoteClient?
    @Published var remoteSelected = false
    @Published var showRemoteBrowser = false
    let discovery = RemoteDiscovery()
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
    func select(_ model: Model) { remoteSelected = false; remote?.setActive(false); selection = model.folder.path; persist() }
    func selectRemote() { remoteSelected = true; remote?.setActive(true) }
    func connect(peer: RemoteDiscovery.Peer, password: String?, remember: Bool) throws {
        guard !models.contains(where: { $0.machine != nil || $0.busy }) else {
            throw RemoteSecurity.failure(L("Сначала выключи локальную VM, чтобы её буфер и раскладка не конфликтовали с удалённой.", "Shut down the local VM first to avoid clipboard and keyboard conflicts."))
        }
        let client = try RemoteClient(peer: peer, password: password, remember: remember)
        remote?.disconnect(); remote = client; remoteSelected = true; showRemoteBrowser = false
    }
    func closeRemote() { remote?.disconnect(); remote = nil; remoteSelected = false }
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
        guard models.count > 1, selected.machine == nil, !selected.busy else { return }
        models.removeAll { $0.folder.path == selection }; selection = models[0].folder.path; persist()
    }
    func start(_ model: Model, install: Bool = false, recovery: Bool = false) {
        guard remote == nil || remote?.ended == true else {
            model.error = L("Сначала отключись от удалённой VM.", "Disconnect from the remote VM first."); return
        }
        // Only one active guest can own the shared host clipboard and resource budget.
        guard !models.contains(where: { $0 !== model && ($0.machine != nil || $0.busy) }) else {
            model.error = L("Сначала приостанови или выключи другую VM. Одновременно работает одна машина.", "Suspend or shut down the other VM first. One machine can run at a time."); return
        }
        if install { model.install() } else { model.start(recovery: recovery) }
    }
}
