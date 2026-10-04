import SwiftUI
import AppKit

struct IsolaMark: View {
    var size: CGFloat = 64
    var body: some View {
        Image(nsImage: NSImage(named: "IsolaIcon") ?? NSImage())
            .resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ChromeButton: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 30, height: 28)
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
            .background(Color.primary.opacity(configuration.isPressed ? 0.13 : selected ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

struct MachineTabs: View {
    @ObservedObject var library: Library
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(library.models, id: \.folder.path) { model in
                        MachineTab(model: model, library: library).id(model.folder.path)
                    }
                }.padding(.horizontal, 2)
            }.onChange(of: library.selection) { scroll.scrollTo(library.selection) }
        }.frame(height: 34)
    }
}

struct AddMachineButton: View {
    @ObservedObject var library: Library
    var body: some View {
        Menu {
            Button(L("Новая машина…", "New Machine…")) { library.add(existing: false) }
            Button(L("Добавить существующую…", "Add Existing Machine…")) { library.add(existing: true) }
        } label: { Image(systemName: "plus").frame(width: 26, height: 28) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("Добавить виртуальную машину", "Add virtual machine"))
            .accessibilityLabel(L("Добавить виртуальную машину", "Add virtual machine"))
    }
}

struct MachineTab: View {
    @ObservedObject var model: Model
    @ObservedObject var library: Library
    @State private var confirmForce = false
    var selected: Bool { library.selection == model.folder.path }
    var body: some View {
        Button { library.select(model) } label: {
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: "desktopcomputer").font(.system(size: 12)).foregroundStyle(selected ? .primary : .secondary) }
                Text(model.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1).frame(minWidth: 50, maxWidth: 140, alignment: .leading)
                if model.error != nil || model.running {
                    Circle().fill(model.error != nil ? Color.orange : Color.green).frame(width: 5, height: 5)
                }
            }.padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(model.name + ", " + (model.running ? L("Работает", "Running") : L("Выключена", "Stopped")))
            .help(model.error ?? model.status)
            .contextMenu {
                Button(L("Настройки…", "Settings…")) { library.select(model); model.settingsVisible = true }
                Divider()
                if model.running {
                    Button(L("Выключить", "Shut Down")) { model.stop() }.disabled(model.busy)
                    Button(L("Принудительно остановить…", "Force Stop…"), role: .destructive) { confirmForce = true }.disabled(model.busy)
                } else {
                    Button(L("Запустить", "Start")) { library.select(model); library.start(model) }.disabled(model.busy || !model.installed)
                    Button(L("Запустить в Recovery", "Start in Recovery")) { library.select(model); library.start(model, recovery: true) }.disabled(model.busy || !model.installed)
                }
                Divider()
                Button(L("Убрать из списка (файлы сохранятся)", "Remove from Library (Keep Files)")) { library.select(model); library.removeSelected() }
                    .disabled(library.models.count < 2 || model.running || model.busy)
            }
            .confirmationDialog(L("Принудительно остановить VM? Несохранённые данные могут быть потеряны.", "Force stop the VM? Unsaved changes may be lost."), isPresented: $confirmForce) {
                Button(L("Остановить", "Force Stop"), role: .destructive) { model.forceStop() }
            }
    }
}

struct MachineControls: View {
    @ObservedObject var model: Model
    @ObservedObject var library: Library
    @State private var confirmForce = false
    var body: some View {
        HStack(spacing: 8) {
            if model.running {
                Menu {
                    Button(L("Выключить macOS", "Shut Down macOS")) { model.stop() }
                    Divider()
                    Button(L("Принудительно остановить…", "Force Stop…"), role: .destructive) { confirmForce = true }
                } label: { Image(systemName: "power").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy)
                    .help(L("Управление питанием", "Power controls"))
                    .accessibilityLabel(L("Управление питанием", "Power controls"))
            } else if model.installed {
                Button { library.start(model) } label: { Image(systemName: "play.fill").font(.system(size: 12)) }
                    .buttonStyle(ChromeButton()).disabled(model.busy)
                    .help(L("Запустить macOS", "Start macOS")).accessibilityLabel(L("Запустить macOS", "Start macOS"))
            }
            Button { model.settingsVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(ChromeButton(selected: model.settingsVisible))
                .help(L("Настройки машины · ⌘,", "Machine settings · ⌘,"))
                .accessibilityLabel(L("Настройки машины", "Machine settings"))
                .accessibilityValue(model.settingsVisible ? L("Открыты", "Shown") : L("Скрыты", "Hidden"))
        }.confirmationDialog(L("Принудительно остановить VM? Несохранённые данные могут быть потеряны.", "Force stop the VM? Unsaved changes may be lost."), isPresented: $confirmForce) {
            Button(L("Остановить", "Force Stop"), role: .destructive) { model.forceStop() }
        }
    }
}

struct ContentView: View {
    @ObservedObject var library: Library
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MachineTabs(library: library)
                AddMachineButton(library: library)
                Divider().frame(height: 16).padding(.horizontal, 2)
                MachineControls(model: library.selected, library: library)
            }
            .padding(.leading, 88).padding(.trailing, 14).frame(height: 48)
            .background(WindowDragArea()).background(TitlebarMaterial())
            Divider().opacity(0.45)
            MachineWorkspace(model: library.selected, library: library).id(library.selection)
        }.ignoresSafeArea().frame(minWidth: 760, minHeight: 480)
    }
}

struct MachineWorkspace: View {
    @ObservedObject var model: Model
    @ObservedObject var library: Library
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if model.machine != nil { GuestScreen(model: model) }
                    else { welcome }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.settingsVisible {
                    Divider()
                    MachineSettings(model: model, library: library)
                        .frame(width: min(390, max(350, geometry.size.width * 0.36)))
                        .background(Color.primary.opacity(0.025))
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .onChange(of: model.error) { if model.error != nil { model.settingsVisible = true } }
    }
    var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            VStack(spacing: 20) {
                IsolaMark(size: 132)
                VStack(spacing: 7) {
                    Text(model.name).font(.system(size: 27, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    Text(model.installed ? L("Готова к работе", "Ready when you are") : L("Твоя macOS. Отдельное пространство.", "Your macOS. A space of its own."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if model.installed {
                    HStack(spacing: 16) {
                        summary("cpu", "\(model.cpus) CPU")
                        summary("memorychip", "\(model.memoryGB) GB")
                        summary("internaldrive", "\(model.diskGB) GB")
                    }.padding(.top, 2)
                }
                if model.busy {
                    VStack(spacing: 10) {
                        if let progress = model.progress { ProgressView(value: progress) }
                        else { ProgressView().controlSize(.small) }
                        Text(model.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: 260).padding(.top, 4)
                } else if model.installed {
                    VStack(spacing: 12) {
                        Button { library.start(model) } label: {
                            Label(L("Запустить macOS", "Start macOS"), systemImage: "play.fill").padding(.horizontal, 16).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button(L("Настройки машины", "Machine Settings")) { model.settingsVisible.toggle() }
                            .buttonStyle(.link).font(.callout)
                    }.padding(.top, 6)
                } else {
                    VStack(spacing: 12) {
                        Text(L("Выбери ресурсы и образ macOS,\nчтобы создать виртуальную машину.", "Choose resources and a macOS image\nto create your virtual machine."))
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(L("Настроить macOS", "Set Up macOS")) { model.settingsVisible = true }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
            }.frame(maxWidth: 420).padding(.horizontal, 22)
            Spacer(minLength: 16)
            HStack(spacing: 7) {
                Image(systemName: model.networkMode == "direct" ? "network" : "network.badge.shield.half.filled")
                Text(model.networkMode == "direct" ? L("Прямое подключение", "Direct connection") : L("Через SOCKS5", "SOCKS5 proxy"))
            }.font(.caption).foregroundStyle(.tertiary).padding(.bottom, 24)
        }
    }
    func summary(_ icon: String, _ value: String) -> some View {
        Label(value, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .fixedSize()
    }
}
