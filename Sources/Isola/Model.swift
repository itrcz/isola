import AppKit
import SwiftUI
import Virtualization
import Security

 enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct SharedFolder: Codable, Identifiable {
    var id = UUID()
    var path: String
    var readOnly = true
    var shareName: String? = nil
    var mountName: String { shareName ?? id.uuidString + "-" + URL(fileURLWithPath: path).lastPathComponent }
}
struct VMRecord: Codable {
    var networkMode: String? = nil; var directRules: String? = nil
    var sharedFolders: [SharedFolder]? = nil; var syncKeyboard: Bool? = nil
    var diskBackup: String? = nil
    var preventGuestSleep: Bool? = nil; var preventHostSleep: Bool? = nil
    var optimizePerformance: Bool? = nil
    var memoryGB: Int; var cpus: Int; var installed: Bool; var macAddress: String? = nil
    var name: String? = nil; var diskGB: Int? = nil
    var proxyHost: String? = nil; var proxyPort: String? = nil; var proxyUser: String? = nil
    var clipboard: Bool? = nil; var hostShortcuts: Bool? = nil; var diskExpansionPending: Bool? = nil
}

@MainActor final class Model: NSObject, ObservableObject, VZVirtualMachineDelegate {
    @Published var host = UserDefaults.standard.string(forKey: "proxy.host") ?? ""
    @Published var port = UserDefaults.standard.string(forKey: "proxy.port") ?? "1080"
    @Published var username = UserDefaults.standard.string(forKey: "proxy.user") ?? ""
    @Published var password = ""
    @Published var networkMode = "proxy"
    @Published var directRules = ""
    @Published var sharedFolders: [SharedFolder] = []
    @Published var syncKeyboard = true
    @Published var optimizePerformance = false
    @Published var performanceStatus = ""
    @Published var preventGuestSleep = false
    @Published var preventHostSleep = false
    @Published var sleepStatus = ""
    @Published var toolsVersion: Int?
    private let hostSleep = SleepInhibitor(keepDisplayAwake: false)
    @Published var integrationStatus = L("Isola Tools: ожидает подключения", "Isola Tools: waiting for connection")
    @Published var keyboardStatus = ""
    @Published var folder = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "vm.folder") ?? (NSHomeDirectory() + "/Library/Application Support/Isola/VM"))
    @Published var ipsw: URL?
    static let maximumMemoryGB = Int(min(ProcessInfo.processInfo.physicalMemory, VZVirtualMachineConfiguration.maximumAllowedMemorySize) / 1_073_741_824)
    static let maximumCPUs = min(ProcessInfo.processInfo.processorCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    var memoryOptions: [Int] { Array(Set([4, 6, 8, 12, 16, Self.maximumMemoryGB].filter { $0 <= Self.maximumMemoryGB })).sorted() }
    var cpuOptions: [Int] { Array(2...max(2, Self.maximumCPUs)) }
    @Published var memoryGB = min(UserDefaults.standard.object(forKey: "vm.memoryGB") as? Int ?? 6, Model.maximumMemoryGB)
    @Published var cpus = min(UserDefaults.standard.object(forKey: "vm.cpus") as? Int ?? 4, Model.maximumCPUs)
    @Published var sharedClipboard = UserDefaults.standard.object(forKey: "vm.clipboard") as? Bool ?? true
    @Published var name = "macOS"
    @Published var diskGB = 64
    @Published var hostShortcuts = true { didSet { displayView?.capturesSystemKeys = !hostShortcuts; UserDefaults.standard.set(hostShortcuts, forKey: "shortcuts." + folder.path) } }
    @Published var settingsVisible = false
    @Published var settingsSection = 0
    @Published var diskExpansionPending = false
    @Published var diskBackup: String?
    var displayView: VZVirtualMachineView?
    @Published var remoteControlActive = false
    lazy var remoteHost = RemoteHost(model: self)
    @Published var busy = false
    @Published var status = L("Выбери режим сети и образ macOS.", "Choose a network mode and a macOS image.")
    @Published var error: String?
    @Published var proxyChecked = false
    @Published var machine: VZVirtualMachine?
    @Published var running = false
    @Published var installed = false
    @Published private(set) var suspended = false
    var savedState: SuspendedState { SuspendedState(folder: folder) }
    var configurationLocked: Bool { machine != nil || savedState.exists }
    var startTitle: String { suspended ? L("Продолжить macOS", "Resume macOS") : L("Запустить macOS", "Start macOS") }
    var stateTitle: String { suspended ? L("Приостановлена", "Suspended") : running ? L("Работает", "Running") : L("Выключена", "Stopped") }
    private var machineConfiguration: VZVirtualMachineConfiguration?
    private var suspending = false
    @Published var progress: Double?
    private var macAddress = "02:49:53:00:00:02"
    private var bridge: NetworkBridge?
    var clipboardBridge: ClipboardBridge?
    private var installer: VZMacOSInstaller?
    private var observation: NSKeyValueObservation?
    private var download: URLSessionDownloadTask?
    private var sessionLock: VMDirectoryLock?
    override convenience init() { self.init(directory: URL(fileURLWithPath: UserDefaults.standard.string(forKey: "vm.folder") ?? (NSHomeDirectory() + "/Library/Application Support/Isola/VM"))) }
    init(directory: URL) {
        super.init(); folder = directory.standardizedFileURL.resolvingSymlinksInPath()
        // Only the legacy VM inherits the legacy global proxy. New machines start blank.
        let legacy = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "vm.folder") ?? (NSHomeDirectory() + "/Library/Application Support/Isola/VM")).standardizedFileURL.resolvingSymlinksInPath()
        if folder != legacy { host = ""; port = "1080"; username = "" }
        reload(); password = readPassword(); settingsVisible = !installed
    }
    var proxy: ProxySettings { ProxySettings(Host: host.trimmingCharacters(in: .whitespacesAndNewlines), Port: Int(port) ?? 0, Username: username, Password: password, DirectRules: directRules.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }
    var recordURL: URL { folder.appendingPathComponent("vm.json") }
    var diskURL: URL { folder.appendingPathComponent("Disk.img") }
    var freeGB: Int { Int(((try? FileManager.default.attributesOfFileSystem(forPath: existingParent(folder).path)[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0) / 1_073_741_824) }
    func existingParent(_ url: URL) -> URL { FileManager.default.fileExists(atPath: url.path) ? url : existingParent(url.deletingLastPathComponent()) }
    func reload() {
        let cached = folder.appendingPathComponent("Restore.ipsw")
        ipsw = FileManager.default.fileExists(atPath: cached.path) ? cached : nil
        error = nil
        if let data = try? Data(contentsOf: recordURL), let record = try? JSONDecoder().decode(VMRecord.self, from: data) { installed = record.installed; memoryGB = record.memoryGB; cpus = record.cpus; macAddress = record.macAddress ?? "02:49:53:00:00:02"
            name = record.name ?? (folder.lastPathComponent == "VM" ? "macOS" : folder.lastPathComponent)
            networkMode = record.networkMode ?? "proxy"; directRules = record.directRules ?? ""
            sharedFolders = record.sharedFolders ?? []; syncKeyboard = record.syncKeyboard ?? true
            // Keep pre-0.6 mount paths stable after removing a different share.
            for index in sharedFolders.indices where sharedFolders[index].shareName == nil {
                sharedFolders[index].shareName = "\(index + 1)-" + URL(fileURLWithPath: sharedFolders[index].path).lastPathComponent
            }
            preventGuestSleep = record.preventGuestSleep ?? false; preventHostSleep = record.preventHostSleep ?? false
            diskExpansionPending = record.diskExpansionPending ?? false
            diskBackup = record.diskBackup
            optimizePerformance = record.optimizePerformance ?? false
            diskGB = actualDiskGB ?? record.diskGB ?? 64
            host = record.proxyHost ?? host; port = record.proxyPort ?? port; username = record.proxyUser ?? username
            sharedClipboard = record.clipboard ?? sharedClipboard; hostShortcuts = UserDefaults.standard.object(forKey: "shortcuts." + folder.path) as? Bool ?? record.hostShortcuts ?? true } else { installed = false }
        suspended = savedState.exists
        status = suspended ? L("VM приостановлена. Нажми «Продолжить macOS».", "VM suspended. Choose Resume macOS.") : installed ? L("Нажми «Запустить macOS».", "Ready to start.") : L("Выбери режим сети и образ macOS.", "Choose a network mode and a macOS image.")
    }
    func chooseImage() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.message = L("Выбери macOS Restore Image (.ipsw) для Apple Silicon", "Choose a macOS Restore Image (.ipsw) for Apple Silicon")
        if p.runModal() == .OK, let url = p.url { if url.pathExtension.lowercased() == "ipsw" { ipsw = url } else { error = L("Нужен файл .ipsw.", "An .ipsw file is required.") } }
    }
    func operation(_ body: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { do { try await body() } catch { self.error = Self.describe(error); self.status = L("Операция не завершена.", "Operation could not be completed.") }; busy = false; progress = nil }
    }
    static func describe(_ error: Error) -> String {
        var parts = [String](), current: NSError? = error as NSError
        for _ in 0..<5 {
            guard let item = current else { break }
            parts.append("\(item.localizedDescription) [\(item.domain):\(item.code)]")
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: "\n")
    }
    func checkNetwork() async throws {
        guard networkMode == "proxy" || networkMode == "direct" else { throw AppError.message("Unknown network mode") }
        if networkMode == "proxy" { try await NetworkBridge.check(proxy) }
    }
    func addSharedFolders() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var proposed = sharedFolders
        for url in panel.urls where !proposed.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
            let base = VZMultipleDirectoryShare.canonicalizedName(from: url.lastPathComponent) ?? "Shared Folder"
            var name = base, suffix = 2
            while proposed.contains(where: { $0.mountName.lowercased() == name.lowercased() }) { name = String(base.prefix(60)) + "-\(suffix)"; suffix += 1 }
            proposed.append(SharedFolder(path: url.path, shareName: name))
        }
        updateSharedFolders(proposed)
    }
    func updateSharedFolders(_ proposed: [SharedFolder]) {
        guard !busy else { return }
        let previous = sharedFolders
        do {
            let share = try Self.directoryShare(proposed)
            sharedFolders = proposed
            if let machine {
                guard let device = machine.directorySharingDevices.first as? VZVirtioFileSystemDevice else { throw AppError.message(L("Перезапусти VM для обновления общих папок.", "Restart the VM to update shared folders.")) }
                try saveRecord(installed: installed)
                device.share = share
            } else { try persistSettings() }
        } catch { sharedFolders = previous; self.error = Self.describe(error) }
    }
    static func directoryShare(_ folders: [SharedFolder]) throws -> VZMultipleDirectoryShare {
        var directories: [String: VZSharedDirectory] = [:]
        for folder in folders {
            let url = URL(fileURLWithPath: folder.path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
            guard values.isDirectory == true, values.isReadable == true else { throw AppError.message(L("Папка недоступна: ", "Folder is unavailable: ") + folder.path) }
            try VZMultipleDirectoryShare.validateName(folder.mountName)
            guard directories[folder.mountName] == nil else { throw AppError.message("Duplicate shared folder name") }
            directories[folder.mountName] = VZSharedDirectory(url: url, readOnly: folder.readOnly)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }

    func checkProxy() { operation { [self] in
        proxyChecked = false; status = L("Проверка настроек сети…", "Checking network settings…"); try await checkNetwork()
        if networkMode == "proxy" { try savePassword() }
        try persistSettings()
        proxyChecked = true; status = L("Настройки сети сохранены.", "Network settings saved.")
    } }
    func requireSpace() throws { guard freeGB >= 45 else { throw AppError.message(L("Свободно \(freeGB) ГБ. Для загрузки и установки нужно минимум 45 ГБ. Выбери папку на внешнем SSD или освободи место.", "Only \(freeGB) GB available. Download and installation require at least 45 GB. Choose an external SSD or free up space.")) } }
    func downloadImage() { operation { [self] in
        let dest = folder.appendingPathComponent("Restore.ipsw")
        guard !FileManager.default.fileExists(atPath: dest.path) else { ipsw = dest; status = L("Используется уже скачанный Restore.ipsw.", "Using the cached Restore.ipsw."); return }
        try requireSpace(); status = L("Поиск совместимого образа Apple…", "Looking for a compatible Apple image…")
        let image = try await VZMacOSRestoreImage.latestSupported
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { observation = nil; download = nil }
        status = L("Загрузка macOS с Apple. Это несколько десятков ГБ…", "Downloading macOS from Apple. This may take a while…")
        let temp: URL = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: image.url) { url, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url, let http = response as? HTTPURLResponse, http.statusCode == 200 else { continuation.resume(throwing: AppError.message(L("Apple не вернул образ macOS.", "Apple did not return a macOS image."))); return }
                do { try FileManager.default.moveItem(at: url, to: dest); continuation.resume(returning: dest) } catch { continuation.resume(throwing: error) }
            }
            download = task
            observation = task.progress.observe(\.fractionCompleted, options: [.new]) { _, change in Task { @MainActor in self.progress = change.newValue } }
            task.resume()
        }
        observation = nil; download = nil; ipsw = temp; status = L("Образ скачан. Можно установить macOS.", "Image downloaded. Ready to install macOS.")
    } }
    func install() { operation { [self] in
        guard let ipsw else { throw AppError.message(L("Выбери образ .ipsw.", "Choose an .ipsw image.")) }
        try requireSpace()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        sessionLock = try VMDirectoryLock(folder: folder)
        defer { observation = nil; installer = nil; if !running { cleanup() } }
        guard !FileManager.default.fileExists(atPath: diskURL.path) else { throw AppError.message(L("В папке уже есть диск VM. Выбери другую пустую папку для новой установки; существующий диск сохранён.", "This folder already contains a VM disk. Choose an empty folder for a new installation. The existing disk was preserved.")) }
        status = L("Проверка сети и образа…", "Checking network and restore image…"); try await checkNetwork()
        let image: VZMacOSRestoreImage = try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: ipsw) { continuation.resume(with: $0) }
        }
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else { throw AppError.message(L("Этот образ несовместим с Mac.", "This image is not compatible with this Mac.")) }
        memoryGB = max(memoryGB, Int((requirements.minimumSupportedMemorySize + 1_073_741_823) / 1_073_741_824)); cpus = max(cpus, requirements.minimumSupportedCPUCount)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requirements.hardwareModel.dataRepresentation.write(to: folder.appendingPathComponent("Hardware.bin"), options: .atomic)
        macAddress = VZMACAddress.randomLocallyAdministered().string
        try VZMacMachineIdentifier().dataRepresentation.write(to: folder.appendingPathComponent("Machine.bin"), options: .atomic)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: folder.appendingPathComponent("Auxiliary.bin"), hardwareModel: requirements.hardwareModel, options: [])
        guard FileManager.default.createFile(atPath: diskURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AppError.message(L("Не удалось создать диск VM.", "Could not create the VM disk.")) }
        let disk = try FileHandle(forWritingTo: diskURL); try disk.truncate(atOffset: UInt64(diskGB) * 1_073_741_824); try disk.close()
        try saveRecord(installed: false)
        do {
            let vm = try await makeMachine(); machine = vm
            let setup = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw); installer = setup
            observation = setup.progress.observe(\.fractionCompleted, options: [.new]) { _, change in Task { @MainActor in self.progress = change.newValue } }
            status = L("Установка macOS…", "Installing macOS…"); try await setup.install()
            try saveRecord(installed: true); installed = true
            // Installer can leave the machine running. Preserve its display and network.
            running = vm.state == .running
            if running { try? hostSleep.setEnabled(preventHostSleep); showVM() } else { cleanup() }
            status = L("macOS установлена.", "macOS installed.")
        } catch { cleanup(); throw error }
        observation = nil; installer = nil
    } }
    func saveRecord(installed: Bool) throws { try JSONEncoder().encode(VMRecord(networkMode: networkMode, directRules: directRules, sharedFolders: sharedFolders, syncKeyboard: syncKeyboard, diskBackup: diskBackup, preventGuestSleep: preventGuestSleep, preventHostSleep: preventHostSleep, optimizePerformance: optimizePerformance, memoryGB: memoryGB, cpus: cpus, installed: installed, macAddress: macAddress, name: name, diskGB: diskGB, proxyHost: host, proxyPort: port, proxyUser: username, clipboard: sharedClipboard, hostShortcuts: hostShortcuts, diskExpansionPending: diskExpansionPending)).write(to: recordURL, options: .atomic) }
    func makeMachine(restoring: Bool = false) async throws -> VZVirtualMachine {
        let hardwareData = try Data(contentsOf: folder.appendingPathComponent("Hardware.bin"))
        let idData = try Data(contentsOf: folder.appendingPathComponent("Machine.bin"))
        guard let hardware = VZMacHardwareModel(dataRepresentation: hardwareData), let identifier = VZMacMachineIdentifier(dataRepresentation: idData) else { throw AppError.message(L("Повреждены файлы конфигурации VM.", "The VM configuration files are damaged.")) }
        guard (2...Self.maximumCPUs).contains(cpus), (4...Self.maximumMemoryGB).contains(memoryGB) else { throw AppError.message(L("Откройте настройки и выберите ресурсы, доступные на этом Mac.", "Open settings and select resources available on this Mac.")) }
        let config = VZVirtualMachineConfiguration(); config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        config.memorySize = UInt64(memoryGB) * 1_073_741_824
        let platform = VZMacPlatformConfiguration(); platform.hardwareModel = hardware; platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: folder.appendingPathComponent("Auxiliary.bin")); config.platform = platform
        let graphics = VZMacGraphicsDeviceConfiguration(); graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)]; config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]; config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false))]
        // Keep the control channel even when features are disabled so the guest can
        // restore old Desktop/Downloads mirrors and receive live sleep preferences.
        do {
            let tools = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Isola Tools.cdr")
            // Pin the read-only Tools media for the whole session, including an
            // app update while suspended. Restore must attach the original bytes.
            if !restoring {
                let data = try Data(contentsOf: tools)
                try data.write(to: savedState.tools, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: savedState.tools.path)
            }
            let toolsDisk = try VZDiskImageStorageDeviceAttachment(url: savedState.tools, readOnly: true)
            config.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: toolsDisk))
            let clipboard = try newClipboardBridge(); clipboardBridge = clipboard
            config.consoleDevices = [clipboard.device]
        }
        // Keep a filesystem device even when empty so folders can be added live.
        let share = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        share.share = try Self.directoryShare(sharedFolders)
        config.directorySharingDevices = [share]
        guard let address = VZMACAddress(string: macAddress), address.isLocallyAdministeredAddress, address.isUnicastAddress else { throw AppError.message(L("Некорректный MAC-адрес VM.", "Invalid VM MAC address.")) }
        let network = VZVirtioNetworkDeviceConfiguration(); network.macAddress = address
        if networkMode == "direct" {
            network.attachment = VZNATNetworkDeviceAttachment(); config.networkDevices = [network]
            try config.validate()
            let vm = VZVirtualMachine(configuration: config); vm.delegate = self; machineConfiguration = config; clipboardBridge?.bind(to: vm); return vm
        }
        var networkSettings = proxy; networkSettings.GuestMAC = macAddress
        let gateway = try NetworkBridge(); bridge = gateway
        do { network.attachment = try await gateway.start(networkSettings); config.networkDevices = [network]; try config.validate() } catch { gateway.stop(); bridge = nil; throw error }
        gateway.onExit = { [weak self, weak gateway] in
            guard let self, let gateway, self.bridge === gateway else { return }
            self.status = L("Сетевой шлюз остановлен. Интернет VM заблокирован.", "Network gateway stopped. Guest internet is blocked.")
        }
        let vm = VZVirtualMachine(configuration: config); vm.delegate = self; machineConfiguration = config; clipboardBridge?.bind(to: vm); return vm
    }
    func start(recovery: Bool = false) { operation { [self] in
        guard installed else { throw AppError.message(L("Сначала установи macOS.", "Install macOS first.")) }
        guard machine == nil else { throw AppError.message(L("VM уже запущена.", "The VM is already running.")) }
        sessionLock = try VMDirectoryLock(folder: folder)
        defer { if !running { cleanup() }; suspended = savedState.exists }
        if savedState.exists {
            reload(); password = readPassword()
            guard !recovery else { throw AppError.message(L("Сначала продолжи VM или удали сохранённое состояние, затем запускай Recovery.", "Resume the VM or discard its saved state before starting Recovery.")) }
            try await restoreSuspendedMachine()
            return
        }
        status = L("Проверка настроек сети…", "Checking network settings…")
        if !recovery { try await checkNetwork() }
        do {
            let vm = try await makeMachine(); machine = vm
            let options = VZMacOSVirtualMachineStartOptions(); options.startUpFromMacOSRecovery = recovery
            try await vm.start(options: options)
            running = true; status = recovery ? L("macOS Recovery работает", "macOS Recovery is running") : L("macOS работает", "macOS is running")
            do { try hostSleep.setEnabled(preventHostSleep) } catch { self.error = Self.describe(error) }
            showVM()
        } catch { cleanup(); throw error }
    } }
    func stop() { guard !busy, let machine else { return }; do { try machine.requestStop(); status = L("Подтвердите выключение на экране гостевой macOS.", "Confirm shutdown on the guest macOS screen.") } catch { self.error = error.localizedDescription } }
    func forceStop() { operation { [self] in if let machine { try await machine.stop() }; cleanup(); status = L("VM остановлена.", "VM stopped.") } }
    func cleanup() { machineConfiguration = nil; remoteHost.stop(); hostSleep.stop(); displayView?.virtualMachine = nil; displayView = nil; machine = nil; clipboardBridge?.stop(); clipboardBridge = nil; bridge?.stop(); bridge = nil; running = false; sessionLock = nil }
    private func newClipboardBridge() throws -> ClipboardBridge {
        try ClipboardBridge(clipboardEnabled: sharedClipboard, syncKeyboard: syncKeyboard, preventSleep: preventGuestSleep, optimizePerformance: optimizePerformance,
                onPerformanceStatus: { [weak self] in self?.performanceStatus = $0 },
                onSleepStatus: { [weak self] in self?.sleepStatus = $0 },
                onToolsVersion: { [weak self] in self?.toolsVersion = $0 },
                onStatus: { [weak self] in self?.integrationStatus = $0 }, onKeyboardStatus: { [weak self] in self?.keyboardStatus = $0 })
    }
    func requireColdMachine() throws {
        guard !configurationLocked else { throw AppError.message(L("Для изменения настроек продолжи VM и выключи macOS, либо удали сохранённое состояние.", "To change settings, resume and shut down macOS, or discard the saved state.")) }
    }
    func suspend() { operation { [self] in try await suspendMachine() } }
    // Also used by the asynchronous Save & Quit flow, which owns the busy flag.
    func suspendMachine() async throws {
        guard let vm = machine, vm.state == .running || vm.state == .paused, let config = machineConfiguration else {
            throw AppError.message(L("Нет работающей VM для сохранения.", "There is no running VM to save."))
        }
        try config.validateSaveRestoreSupport()
        guard !savedState.exists else { throw AppError.message(L("Сначала устрани незавершённое сохранение VM.", "Resolve the unfinished saved state first.")) }
        guard freeGB >= memoryGB + 2 else {
            throw AppError.message(L("Для паузы нужно хотя бы \(memoryGB + 2) ГБ свободного места на хосте.", "Suspending needs at least \(memoryGB + 2) GB free on the host."))
        }
        suspending = true
        defer { suspending = false; suspended = savedState.exists }
        remoteHost.stop()
        status = L("Подготовка к паузе…", "Preparing to suspend…")
        var committed = false
        var integrationDisconnected = false
        do {
            try await clipboardBridge?.disconnectForSuspend()
            clipboardBridge?.stop(); clipboardBridge = nil
            integrationDisconnected = true
            if vm.state == .running { try await vm.pause() }
            let target = try savedState.begin()
            status = L("Сохранение памяти VM…", "Saving VM memory…")
            try await vm.saveMachineStateTo(url: target)
            try savedState.commit(); committed = true
            // Do not release the VM lock until Virtualization releases the disk.
            try await vm.stop()
            try savedState.finishStopping()
            cleanup()
            status = L("VM приостановлена. Можно закрыть Isola.", "VM suspended. You can quit Isola.")
        } catch {
            if vm.state == .stopped { cleanup() }
            else {
                // If committing failed, remove even a completed rename before
                // letting the original CPU run again against its disk.
                do {
                    if committed || FileManager.default.fileExists(atPath: savedState.committed.path) { try savedState.discard() }
                    else { try savedState.cancelPreparation() }
                    if integrationDisconnected {
                        let clipboard = try newClipboardBridge(); clipboardBridge = clipboard
                        clipboard.bind(to: vm); clipboard.reconnect()
                    }
                    if vm.state == .paused { try await vm.resume() }
                    running = vm.state == .running
                } catch let rollbackError {
                    running = false
                    throw AppError.message(Self.describe(error) + "\n" + Self.describe(rollbackError))
                }
            }
            throw error
        }
    }
    private func restoreSuspendedMachine() async throws {
        status = L("Проверка сохранённого состояния…", "Checking saved state…")
        _ = try savedState.validate()
        // Reopen the configured adapter even if the SOCKS server is temporarily
        // offline. The gateway still fails closed; apps can reconnect later.
        let vm = try await makeMachine(restoring: true); machine = vm
        try machineConfiguration?.validateSaveRestoreSupport()
        status = L("Восстановление памяти VM…", "Restoring VM memory…")
        try await vm.restoreMachineStateFrom(url: savedState.stateFile)
        try savedState.consume()
        // The guest helper closed the old console before suspension. Reattach
        // a fresh endpoint; its LaunchAgent reconnects and negotiates settings.
        clipboardBridge?.reconnect()
        try await vm.resume()
        running = true
        try savedState.finishResume()
        suspended = false
        try? hostSleep.setEnabled(preventHostSleep)
        status = L("macOS продолжает работу", "macOS resumed")
        showVM()
    }
    func discardSavedState() { operation { [self] in
        guard machine == nil else { throw AppError.message(L("Сначала останови VM.", "Stop the VM first.")) }
        let lock = try VMDirectoryLock(folder: folder); defer { withExtendedLifetime(lock) {}; suspended = savedState.exists }
        try savedState.discard()
        status = L("Сохранённая память удалена. Диск VM сохранён.", "Saved memory discarded. The VM disk was kept.")
    } }
    func setPerformance(_ enabled: Bool) {
        guard !busy else { return }
        let previous = optimizePerformance
        optimizePerformance = enabled
        do {
            if machine != nil { try saveRecord(installed: installed) }
            else { try persistSettings() }
            if let clipboardBridge { clipboardBridge.setPerformance(enabled) }
            else { performanceStatus = L("Применится после запуска VM и подключения Isola Tools.", "Applies when the VM starts and Isola Tools connects.") }
        } catch { optimizePerformance = previous; self.error = Self.describe(error) }
    }
    func setSleep(guest: Bool? = nil, host: Bool? = nil) {
        guard !busy else { return }
        let oldGuest = preventGuestSleep, oldHost = preventHostSleep
        if let guest { preventGuestSleep = guest }
        if let host { preventHostSleep = host }
        do {
            try hostSleep.setEnabled(running && preventHostSleep)
            if machine != nil { try saveRecord(installed: installed) } else { try persistSettings() }
            if guest != nil {
                if let clipboardBridge { clipboardBridge.setPreventSleep(preventGuestSleep) }
                else { sleepStatus = L("Применится после запуска VM и подключения Isola Tools.", "Applies when the VM starts and Isola Tools connects.") }
            }
        } catch {
            preventGuestSleep = oldGuest; preventHostSleep = oldHost
            try? hostSleep.setEnabled(running && oldHost)
            self.error = Self.describe(error)
        }
    }
    func switchKeyboard() {
        guard syncKeyboard, machine != nil else { return }
        if InputSources.cycle() { clipboardBridge?.publishKeyboard() }
        else { keyboardStatus = "Добавьте второй источник ввода в настройках клавиатуры хоста." }
    }
    func showVM() { settingsVisible = false; NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
    var actualDiskGB: Int? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: diskURL.path)[.size]) as? NSNumber else { return nil }
        return Int(size.uint64Value / 1_073_741_824)
    }
    var allocatedDiskGB: Int {
        let size = try? diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
        return Int((size ?? 0) / 1_073_741_824)
    }
    func persistSettings() throws {
        try requireColdMachine()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try VMDirectoryLock(folder: folder); defer { withExtendedLifetime(lock) {} }
        try requireColdMachine()
        try saveRecord(installed: installed)
    }
    func saveResources(cpu: Int, memory: Int, disk: Int, title: String, completion: @escaping () -> Void) {
        operation { [self] in
            try requireColdMachine()
            guard (2...Self.maximumCPUs).contains(cpu), (4...Self.maximumMemoryGB).contains(memory), (64...2048).contains(disk), disk >= (actualDiskGB ?? 64) else { throw AppError.message("Некорректный размер диска или ресурсы.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lock = try VMDirectoryLock(folder: folder)
            defer { withExtendedLifetime(lock) {} }
            try requireColdMachine()
            if installed && (disk > (actualDiskGB ?? disk) || diskExpansionPending) {
                status = "Подготовка резервной копии и расширение основного тома…"
                let directory = folder, bytes = UInt64(disk) * 1_073_741_824
                let backup = try await Task.detached {
                    try DiskExpansion.expand(folder: directory, bytes: bytes) { message in
                        Task { @MainActor in self.status = message }
                    }
                }.value
                diskBackup = backup.path; diskExpansionPending = false
            }
            cpus = cpu; memoryGB = memory; diskGB = disk
            name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "macOS" : title
            try saveRecord(installed: installed)
            status = "Настройки сохранены. Основной том использует доступное место; Recovery сохранён."
            completion()
        }
    }
    func applyResources(cpu: Int, memory: Int, disk: Int, title: String) throws {
        guard !busy else { throw AppError.message(L("Дождись завершения операции.", "Wait for the current operation.")) }; try requireColdMachine()
        guard (2...Self.maximumCPUs).contains(cpu), (4...Self.maximumMemoryGB).contains(memory), (64...2048).contains(disk) else { throw AppError.message(L("Ресурсы вне допустимого диапазона.", "Resources are outside the supported range.")) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try VMDirectoryLock(folder: folder); defer { withExtendedLifetime(lock) {} }
        try requireColdMachine()
        let oldDisk = actualDiskGB
        guard disk >= (oldDisk ?? 64) else { throw AppError.message(L("Уменьшение диска не поддерживается.", "Shrinking a disk is not supported.")) }
        if let oldDisk, disk > oldDisk {
            throw AppError.message(L("Для увеличения используйте расширение APFS через настройки машины.", "Use the machine settings to expand APFS."))
        }
        let before = (cpus, memoryGB, diskGB, name)
        cpus = cpu; memoryGB = memory; diskGB = disk; name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "macOS" : title
        do { try saveRecord(installed: installed) } catch {
            // A successful image growth is safe to keep; never truncate it back on a metadata error.
            cpus = before.0; memoryGB = before.1; diskGB = actualDiskGB ?? before.2; name = before.3; throw error
        }
        error = nil
        status = L("Настройки сохранены. Применятся при следующем запуске.", "Settings saved. They take effect on the next start.")
    }
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) { Task { @MainActor in
        guard self.machine === virtualMachine, self.installer == nil, !self.suspending else { return }
        self.cleanup(); self.status = L("macOS выключена.", "macOS shut down.")
    } }
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { Task { @MainActor in
        guard self.machine === virtualMachine, self.installer == nil, !self.suspending else { return }
        self.cleanup(); self.error = Self.describe(error); self.status = L("VM остановлена из-за ошибки.", "VM stopped due to an error.")
    } }
    private var key: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.isola.proxy", kSecAttrAccount as String: "\(host):\(port):\(username)"] }
    func readPassword() -> String { var q = key; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne; var result: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }; return String(data: data, encoding: .utf8) ?? "" }
    func savePassword() throws { var attrs: [String: Any] = [kSecValueData as String: Data(password.utf8)]; var code = SecItemUpdate(key as CFDictionary, attrs as CFDictionary); if code == errSecItemNotFound { attrs.merge(key) { a,_ in a }; attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly; code = SecItemAdd(attrs as CFDictionary, nil) }; guard code == errSecSuccess else { throw AppError.message(L("Не удалось сохранить пароль в Связке ключей (\(code)).", "Could not save the password in Keychain (\(code)).")) } }
}
