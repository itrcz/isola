import SwiftUI
import AppKit

// Semantic system colors keep the inspector legible in either appearance.
struct SettingsGroup<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 3)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }
}

struct SettingsHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
    }
}

struct PreferenceToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty { SettingsHint(subtitle) }
            }.padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.mini).accessibilityLabel(title)
    }
}

struct SettingsDetails<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { content }.padding(.top, 8)
        } label: { Text(title).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
}

struct MachineSettings: View {
    @ObservedObject var model: Model
    @ObservedObject var library: Library
    @State private var cpu = 4
    @State private var memory = 6
    @State private var disk = 64
    @State private var title = "macOS"
    @State private var saved = false
    @State private var expandConfirm = false
    var section: Int { model.settingsSection }
    var locked: Bool { model.busy || model.machine != nil }
    var resourcesChanged: Bool { cpu != model.cpus || memory != model.memoryGB || disk != (model.actualDiskGB ?? model.diskGB) || title != model.name }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Настройки", "Settings")).font(.system(size: 17, weight: .semibold))
                    Text(model.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { model.settingsVisible = false } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(ChromeButton()).help(L("Закрыть настройки", "Close settings"))
                    .accessibilityLabel(L("Закрыть настройки", "Close settings"))
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
            Picker(L("Раздел настроек", "Settings section"), selection: $model.settingsSection) {
                Text(L("Машина", "Machine")).tag(0)
                Text(L("Сеть", "Network")).tag(1)
                Text(L("Интеграция", "Integration")).tag(2)
            }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 16)
            Divider().opacity(0.5)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Color.clear.frame(height: 0).id("settings-top")
                        if let error = model.error { errorNotice(error) }
                        if model.busy {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(model.status).font(.caption).fixedSize(horizontal: false, vertical: true)
                                if let progress = model.progress { ProgressView(value: progress) }
                                else { ProgressView().controlSize(.small) }
                            }
                        }
                        if locked && section != 2 {
                            Label(L("Выключи macOS, чтобы изменить настройки.", "Shut down macOS to edit these settings."), systemImage: "lock")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if section == 0 { resources }
                        if section == 1 { network }
                        if section == 2 { integration }
                    }.padding(.horizontal, 20).padding(.bottom, 24)
                }.onChange(of: section) { scroll.scrollTo("settings-top", anchor: .top) }
                    .onChange(of: model.error) { if model.error != nil { scroll.scrollTo("settings-top", anchor: .top) } }
            }
        }.textFieldStyle(.roundedBorder)
            .onAppear { resetDraft() }
            .onChange(of: cpu) { saved = false }
            .onChange(of: memory) { saved = false }
            .onChange(of: disk) { saved = false }
            .onChange(of: title) { saved = false }
            .onChange(of: model.host) { model.proxyChecked = false }
            .onChange(of: model.port) { model.proxyChecked = false }
            .onChange(of: model.username) { model.proxyChecked = false }
            .onChange(of: model.password) { model.proxyChecked = false }
            .confirmationDialog(L("Увеличить диск macOS?", "Expand the macOS disk?"), isPresented: $expandConfirm) {
                Button(L("Увеличить и сохранить", "Expand and Save")) { save() }
                Button(L("Отмена", "Cancel"), role: .cancel) { }
            } message: {
                Text(L("Isola сохранит резервную копию, перенесёт Recovery и расширит основной том. Выключи VM перед продолжением.", "Isola will save a backup, relocate Recovery and expand the main volume. The VM must be shut down."))
            }
    }

    var resources: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: L("Основные", "General"), icon: "desktopcomputer") {
                HStack {
                    Text(L("Имя", "Name")).font(.system(size: 12))
                    Spacer(minLength: 16)
                    TextField(L("Имя машины", "Machine name"), text: $title).multilineTextAlignment(.trailing).frame(maxWidth: 210)
                }.disabled(locked)
                if model.installed {
                    Divider()
                    HStack {
                        Label(model.running ? L("Работает", "Running") : L("Выключена", "Stopped"), systemImage: model.running ? "circle.fill" : "circle")
                            .font(.system(size: 11)).foregroundStyle(model.running ? Color.green : Color.secondary)
                        Spacer()
                        if model.running {
                            Button(L("Выключить…", "Shut Down")) { model.stop() }.disabled(model.busy)
                        } else {
                            Menu(L("Запуск", "Start Up")) {
                                Button(L("Запустить macOS", "Start macOS")) { library.start(model) }
                                Button(L("Запустить в Recovery", "Start in Recovery")) { library.start(model, recovery: true) }
                            }.fixedSize().disabled(model.busy)
                        }
                    }
                }
            }
            SettingsGroup(title: L("Ресурсы", "Resources"), icon: "cpu") {
                Stepper(value: $cpu, in: 2...Model.maximumCPUs) {
                    HStack { Text(L("Ядра CPU", "Processor")); Spacer(); Text(L("\(cpu)", "\(cpu) cores")).foregroundStyle(.secondary).monospacedDigit() }
                }.font(.system(size: 12)).disabled(locked)
                Divider()
                Stepper(value: $memory, in: 4...Model.maximumMemoryGB) {
                    HStack { Text(L("Память", "Memory")); Spacer(); Text("\(memory) GB").foregroundStyle(.secondary).monospacedDigit() }
                }.font(.system(size: 12)).disabled(locked)
                if memory > Model.maximumMemoryGB - 4 {
                    Label(L("Оставь хосту хотя бы 4 ГБ памяти.", "Leave at least 4 GB for the host."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Divider()
                HStack {
                    Text(L("Размер диска", "Disk capacity")).font(.system(size: 12))
                    Spacer()
                    TextField("GB", value: $disk, format: .number.grouping(.never)).multilineTextAlignment(.trailing).frame(width: 64)
                        .accessibilityLabel(L("Размер диска в ГБ", "Disk capacity in GB"))
                    Text("GB").font(.caption).foregroundStyle(.secondary)
                }.disabled(locked)
                SettingsHint(L("На хосте занято \(model.allocatedDiskGB) ГБ · свободно \(model.freeGB) ГБ", "\(model.allocatedDiskGB) GB used on host · \(model.freeGB) GB available"))
                SettingsDetails(title: L("Как работает размер диска", "About disk capacity")) {
                    SettingsHint(L("Образ занимает место по мере записи. Диск можно увеличить до 2048 ГБ; уменьшение не поддерживается. При увеличении Isola сохранит резервную копию и автоматически расширит основной том macOS.", "The image uses space as data is written. Capacity can grow up to 2048 GB; shrinking is not supported. Isola saves a backup and expands the main macOS volume automatically."))
                }
            }
            HStack {
                if saved { Label(L("Сохранено", "Saved"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                else if resourcesChanged { Text(L("Есть изменения", "Unsaved changes")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L("Сохранить", "Save Changes")) {
                    if let current = model.actualDiskGB, disk > current { expandConfirm = true } else { save() }
                }.buttonStyle(.borderedProminent).disabled(locked || (!resourcesChanged && model.installed))
            }
            if model.diskExpansionPending {
                SettingsGroup(title: L("Свободное место", "Unused Capacity"), icon: "internaldrive.badge.plus") {
                    SettingsHint(L("На диске есть место, которое ещё не добавлено в основной том macOS.", "The disk has unused space that is not yet part of the main macOS volume."))
                    Button(L("Расширить основной том…", "Expand Main Volume…")) { disk = model.actualDiskGB ?? disk; expandConfirm = true }.disabled(locked)
                }
            }
            if !model.installed { installation }
            SettingsGroup(title: L("Хранение", "Storage"), icon: "folder") {
                Button { NSWorkspace.shared.open(model.folder) } label: {
                    HStack { Text(L("Файлы виртуальной машины", "Virtual Machine Files")); Spacer(); Image(systemName: "arrow.up.right") }
                }.buttonStyle(.plain).font(.system(size: 12)).help(model.folder.path)
                if let backup = model.diskBackup {
                    Divider()
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: backup)) } label: {
                        HStack { Text(L("Резервная копия", "Disk Expansion Backup")); Spacer(); Image(systemName: "arrow.up.right") }
                    }.buttonStyle(.plain).font(.system(size: 12))
                }
                SettingsDetails(title: L("Путь и восстановление", "Location and recovery")) {
                    Text(model.folder.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if model.diskBackup != nil { SettingsHint(L("Чтобы восстановиться, выключи VM и добавь папку резервной копии как существующую машину.", "To restore, shut down the VM and add the backup folder as an existing machine.")) }
                }
            }
        }
    }

    var installation: some View {
        SettingsGroup(title: L("Установка macOS", "Install macOS"), icon: "square.and.arrow.down") {
            Label(model.ipsw?.lastPathComponent ?? L("Образ macOS не выбран", "No macOS image selected"), systemImage: "doc.zipper")
                .font(.system(size: 12)).lineLimit(2).help(model.ipsw?.path ?? "")
            HStack {
                Button(L("Выбрать IPSW…", "Choose IPSW…")) { model.chooseImage() }
                Button(L("Скачать…", "Download…")) { model.downloadImage() }
            }.disabled(locked)
            SettingsHint(L("Образ для Apple Silicon с серверов Apple. Для скачивания и установки нужно от 45 ГБ.", "An Apple Silicon restore image from Apple. Downloading and installing requires at least 45 GB."))
            Button(L("Установить macOS", "Install macOS")) { save(); if saved { library.start(model, install: true) } }
                .buttonStyle(.borderedProminent).disabled(locked || model.ipsw == nil)
        }
    }

    var network: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: L("Подключение", "Connection"), icon: "network") {
                Picker(L("Режим", "Mode"), selection: $model.networkMode) {
                    Text(L("Напрямую", "Direct")).tag("direct")
                    Text(L("Через прокси", "Proxy")).tag("proxy")
                }.labelsHidden().pickerStyle(.segmented).disabled(locked)
                    .onChange(of: model.networkMode) { model.proxyChecked = false; persist() }
                SettingsHint(model.networkMode == "direct"
                    ? L("Гостевая macOS использует интернет хоста через NAT.", "The guest uses your Mac’s internet connection through NAT.")
                    : L("Трафик идёт через SOCKS5. Прямого выхода при сбое прокси нет.", "Traffic uses SOCKS5, with no direct fallback if the proxy fails."))
            }
            if model.networkMode == "proxy" {
                SettingsGroup(title: "SOCKS5", icon: "server.rack") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("Адрес и порт", "Server and port")).font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack {
                            TextField(L("IP-адрес сервера", "Server IP address"), text: $model.host)
                                .accessibilityLabel(L("Адрес прокси", "Proxy server"))
                            TextField("1080", text: $model.port).frame(width: 65).accessibilityLabel(L("Порт прокси", "Proxy port"))
                        }
                    }
                    Divider()
                    TextField(L("Логин — необязательно", "Username (optional)"), text: $model.username)
                    SecureField(L("Пароль — необязательно", "Password (optional)"), text: $model.password)
                }.disabled(locked)
                SettingsGroup(title: L("Напрямую, минуя прокси", "Bypass Proxy"), icon: "arrow.triangle.branch") {
                    SettingsHint(L("IP, подсеть или домен — по одному правилу в строке.", "One IP address, subnet or domain per line."))
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.directRules).scrollContentBackground(.hidden)
                            .font(.system(size: 11, design: .monospaced)).padding(5)
                            .accessibilityLabel(L("Правила прямого подключения", "Direct connection rules"))
                            .onChange(of: model.directRules) { model.proxyChecked = false }
                        if model.directRules.isEmpty {
                            Text("*company.com\n10.0.0.0/8\n203.0.113.5").font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary).padding(10).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }.frame(height: 100).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)).disabled(locked)
                    SettingsDetails(title: L("Как работают исключения", "How domain rules work")) {
                        SettingsHint(L("Исключения доменов используют DNS гостя. DNS over HTTPS обходит их; общий IP может затронуть другие сайты. Прокси поддерживает TCP и DNS.", "Domain rules use guest DNS. DNS over HTTPS bypasses them; shared IPs may affect other sites. The proxy supports TCP and DNS."))
                    }
                }
            }
            HStack {
                if model.proxyChecked { Label(L("Сохранено", "Saved"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                Spacer()
                Button(model.networkMode == "direct" ? L("Сохранить", "Save Connection") : L("Проверить и сохранить", "Test and Save")) { model.checkProxy() }
                    .buttonStyle(.borderedProminent).disabled(locked)
            }
            SettingsHint(L("Изменения применятся при следующем запуске macOS.", "Changes take effect the next time you start macOS."))
        }
    }

    var integration: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: L("Комфорт", "Experience"), icon: "slider.horizontal.3") {
                PreferenceToggle(title: L("Оптимизировать производительность", "Optimize performance"), subtitle: L("Меньше анимаций, прозрачности и размытия.", "Reduce motion, transparency and blur."), isOn: Binding(get: { model.optimizePerformance }, set: { model.setPerformance($0) })).disabled(model.busy)
                if !model.performanceStatus.isEmpty { SettingsHint(model.performanceStatus) }
                Divider()
                PreferenceToggle(title: L("Сочетания клавиш на хосте", "Keep shortcuts on this Mac"), subtitle: L("Cmd+Tab и системные сочетания управляют хостом.", "Cmd+Tab and system shortcuts control the host."), isOn: $model.hostShortcuts)
                    .onChange(of: model.hostShortcuts) { if model.machine == nil { persist() } }
                SettingsDetails(title: L("Применяется сразу", "Applies while running")) {
                    SettingsHint(L("Оптимизация требует обновлённого Isola Tools. Отключение вернёт прежние настройки эффектов. Некоторым приложениям нужен перезапуск или повторный вход в гостевую macOS. Отключи сочетания хоста, чтобы передавать их гостю.", "Optimization requires updated Isola Tools. Turning it off restores previous visual settings. Some apps need reopening or a guest logout. Turn off host shortcuts to send them to the guest."))
                }
            }
            SettingsGroup(title: L("Связь с хостом", "Continuity"), icon: "link") {
                PreferenceToggle(title: L("Общий буфер обмена", "Shared clipboard"), subtitle: L("Текст, изображения и файлы в обе стороны.", "Copy text, images and files between systems."), isOn: $model.sharedClipboard)
                    .disabled(locked).onChange(of: model.sharedClipboard) { persist() }
                Divider()
                PreferenceToggle(title: L("Общая раскладка", "Sync keyboard layout"), subtitle: L("Cmd+Space меняет язык в обеих системах.", "Cmd+Space switches both systems together."), isOn: $model.syncKeyboard)
                    .disabled(locked).onChange(of: model.syncKeyboard) { persist() }
                SettingsDetails(title: L("Условия и ограничения", "Requirements and limits")) {
                    SettingsHint(L("Нужен Isola Tools. Текст и изображения — до 10 МиБ, файлы — до 64 МиБ суммарно, без папок. Та же раскладка должна быть доступна в госте.", "Requires Isola Tools. Text and images: up to 10 MiB. Files: up to 64 MiB total, excluding folders. The same input source must be available in the guest."))
                }
            }
            SettingsGroup(title: L("Общие папки", "Shared Folders"), icon: "folder") {
                PreferenceToggle(title: L("Рабочий стол", "Desktop"), subtitle: "", isOn: $model.mirrorDesktop)
                    .disabled(locked).onChange(of: model.mirrorDesktop) { persist() }
                Divider()
                PreferenceToggle(title: L("Загрузки", "Downloads"), subtitle: "", isOn: $model.mirrorDownloads)
                    .disabled(locked).onChange(of: model.mirrorDownloads) { persist() }
                SettingsHint(L("Одни файлы в обеих системах. Изменения и удаления тоже общие.", "The same files in both systems. Edits and deletions are shared too."))
                SettingsDetails(title: L("Где прежние файлы гостя", "Where guest files are kept")) {
                    SettingsHint(L("Прежние Desktop и Downloads сохранены в ~/Library/Application Support/Isola Integration. При отключении общих папок они вернутся на место.", "Original Desktop and Downloads folders are saved in ~/Library/Application Support/Isola Integration and restored when sharing is turned off."))
                }
                if !model.sharedFolders.isEmpty { Divider() }
                ForEach($model.sharedFolders) { $folder in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            Text(URL(fileURLWithPath: folder.path).lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(folder.path)
                            Spacer()
                            Button { model.sharedFolders.removeAll { $0.id == folder.id }; persist() } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).help(L("Отключить папку", "Stop sharing folder"))
                                .accessibilityLabel(L("Отключить папку ", "Stop sharing ") + URL(fileURLWithPath: folder.path).lastPathComponent)
                        }
                        Toggle(L("Только чтение", "Read only"), isOn: $folder.readOnly).font(.caption).onChange(of: folder.readOnly) { persist() }
                    }.disabled(locked)
                    Divider()
                }
                Button { model.addSharedFolders() } label: { Label(L("Добавить папку…", "Add Folder…"), systemImage: "plus") }
                    .disabled(locked)
            }
            if locked {
                Label(L("Буфер, раскладка и папки меняются при выключенной macOS.", "Shut down macOS to change clipboard, layout and folder sharing."), systemImage: "lock")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsHint(L("Буфер, раскладка и папки применятся при следующем запуске.", "Clipboard, layout and folder changes apply on the next start."))
            }
            SettingsGroup(title: "Isola Tools", icon: "puzzlepiece.extension") {
                SettingsHint(model.integrationStatus)
                if !model.keyboardStatus.isEmpty { SettingsHint(model.keyboardStatus) }
                SettingsDetails(title: L("Установка и помощь", "Setup and Help")) {
                    SettingsHint(L("В госте открой диск Isola Tools и запусти Install Clipboard.command. Для обновления запусти его снова. Дополнительные папки доступны в Finder → My Shared Files.", "In the guest, open the Isola Tools disk and run Install Clipboard.command. Run it again to update. Additional folders appear in Finder → My Shared Files."))
                }
            }
        }
    }

    func errorNotice(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Не удалось завершить действие", "Couldn’t Complete Action"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            Text(error).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    func resetDraft() { cpu = model.cpus; memory = model.memoryGB; disk = model.actualDiskGB ?? model.diskGB; title = model.name }
    func save() {
        saved = false
        if model.installed { model.saveResources(cpu: cpu, memory: memory, disk: disk, title: title) { saved = true } }
        else { do { try model.applyResources(cpu: cpu, memory: memory, disk: disk, title: title); saved = true } catch { model.error = Model.describe(error) } }
    }
    func persist() { do { try model.persistSettings() } catch { model.error = Model.describe(error) } }
}
