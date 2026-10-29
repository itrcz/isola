import SwiftUI
import AppKit

struct RemoteSharingSettings: View {
    @ObservedObject var host: RemoteHost
    let running: Bool
    @State private var password = ""
    var body: some View {
        SettingsGroup(title: L("Доступ по сети", "Network Sharing"), icon: "network") {
            PreferenceToggle(title: L("Разрешить подключение к VM", "Share this VM"), subtitle: L("Другие Mac с Isola увидят её в локальной сети.", "Other Macs with Isola can discover it on this network."), isOn: Binding(get: { host.enabled }, set: { host.setEnabled($0) }))
                .disabled(!running && !host.enabled)
            if !running { SettingsHint(L("Сначала запусти виртуальную машину.", "Start the virtual machine first.")) }
            if !host.status.isEmpty { SettingsHint(host.status) }
            PreferenceToggle(title: L("Защитить паролем", "Require a password"), subtitle: L("Без защиты подключиться может любой в этой сети.", "Without protection, anyone on this network can connect."), isOn: Binding(get: { host.passwordProtected }, set: { host.setPasswordProtected($0) }))
            if host.passwordProtected {
                HStack {
                    SecureField(L("Задать или сменить пароль", "Set or change password"), text: $password).textFieldStyle(.roundedBorder)
                    Button(L("Сохранить", "Save")) { host.savePassword(password); password = "" }.disabled(password.isEmpty || password.utf8.count > 1024)
                }
                SettingsHint(L("Смена пароля отключит текущего клиента.", "Changing the password disconnects the current client."))
            }
            if host.enabled {
                if host.controlling { Button(L("Забрать управление", "Take Control")) { host.takeControl() } }
                SettingsHint(L("На другом Mac: + → В локальной сети → выбери VM → Подключиться.", "On another Mac: + → Local Network → select the VM → Connect."))
            }
            SettingsDetails(title: L("Как это работает", "How It Works")) {
                SettingsHint(L("Один управляющий клиент, шифрованное соединение. Хост и Isola должны работать; при необходимости включи ниже запрет сна хоста. Буфер и раскладка связывают клиента с гостем через Isola Tools. Доступ выключается при остановке VM.", "One controlling client over an encrypted connection. Keep the host and Isola running; enable the host sleep setting below if needed. Clipboard and layout connect the client to the guest through Isola Tools. Sharing turns off when the VM stops."))
            }
        }
    }
}

struct RemoteBrowserSheet: View {
    @ObservedObject var library: Library
    @ObservedObject var discovery: RemoteDiscovery
    @State private var selected = ""
    @State private var password = ""
    @State private var remember = true
    @State private var error: String?
    var peer: RemoteDiscovery.Peer? { discovery.peers.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "network").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("В локальной сети", "Local Network")).font(.title2.weight(.semibold))
                    Text(L("Подключись к macOS на другом Mac.", "Connect to macOS running on another Mac.")).foregroundStyle(.secondary)
                }
            }
            if discovery.peers.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(L("Ищем виртуальные машины…", "Looking for virtual machines…")).font(.callout)
                    Text(L("На хосте запусти VM и включи доступ в Настройках → Интеграция. Оба Mac должны быть в одной сети.", "Start the VM on the host and enable sharing in Settings → Integration. Both Macs must be on the same network."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }.frame(maxWidth: .infinity).frame(height: 160)
            } else {
                List(discovery.peers, selection: $selected) { peer in
                    HStack { Label(peer.name, systemImage: "desktopcomputer"); Spacer(); Image(systemName: peer.protected ? "lock.fill" : "lock.open").foregroundStyle(.secondary) }.padding(.vertical, 6).tag(peer.id)
                }.listStyle(.bordered).frame(height: 160)
            }
            if peer?.protected == true {
                SecureField(L("Пароль для этой VM", "Password for this VM"), text: $password).textFieldStyle(.roundedBorder)
                Toggle(L("Запомнить пароль в Связке ключей", "Remember password in Keychain"), isOn: $remember).font(.callout)
            }
            if let message = error ?? discovery.error { Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(L("Экран, клавиатура, мышь и буфер обмена.", "Screen, keyboard, mouse and clipboard.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Отмена", "Cancel")) { library.showRemoteBrowser = false }.keyboardShortcut(.cancelAction)
                Button(L("Подключиться", "Connect")) {
                    guard let peer else { return }
                    do { try library.connect(peer: peer, password: peer.protected ? password : nil, remember: remember) } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(peer == nil || (peer?.protected == true && password.isEmpty))
            }
        }.padding(24).frame(width: 540)
            .onAppear { discovery.start() }.onDisappear { discovery.stop() }
            .onChange(of: selected) { password = RemoteSecurity.savedPassword(account: "peer:" + selected) ?? ""; error = nil }
    }
}

struct RemoteTab: View {
    @ObservedObject var client: RemoteClient
    @ObservedObject var library: Library
    var body: some View {
        Button { library.selectRemote() } label: {
            HStack(spacing: 8) {
                Image(systemName: "network").font(.system(size: 12))
                Text(client.name).font(.system(size: 12, weight: library.remoteSelected ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 150)
                Circle().fill(client.connected ? Color.green : Color.orange).frame(width: 5, height: 5)
            }.padding(.horizontal, 12).frame(height: 30)
        }.buttonStyle(.plain).background(library.remoteSelected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .help(client.status).contextMenu { Button(L("Отключиться", "Disconnect")) { library.closeRemote() } }
    }
}

struct RemoteWorkspace: View {
    @ObservedObject var client: RemoteClient
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                RemoteScreen(client: client)
                if !client.hasFrame || client.ended {
                    VStack(spacing: 14) {
                        if !client.ended { ProgressView().colorScheme(.dark) }
                        else { Image(systemName: "network.slash").font(.largeTitle) }
                        Text(client.status).multilineTextAlignment(.center).frame(maxWidth: 450)
                    }.padding(24).foregroundStyle(.white).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text(client.status).lineLimit(1)
                Spacer()
                Text(client.statistics).monospacedDigit().lineLimit(1)
                    .help(L("RTT — время туда-обратно по сети, не полная задержка экрана. FPS снижается на неподвижном рабочем столе.", "RTT measures the network round trip, not total display latency. FPS falls on a static desktop."))
                Menu {
                    Picker(L("Качество", "Quality"), selection: $client.quality) {
                        Text(L("Retina · чёткий текст", "Retina · sharp text")).tag("retina")
                        Text(L("Сбалансированный", "Balanced")).tag("balanced")
                        Text(L("Быстрый отклик · H.264", "Responsive · H.264")).tag("responsive")
                    }
                } label: { Image(systemName: "display") }.menuStyle(.borderlessButton).frame(width: 28)
                    .help(L("Масштаб и качество потока", "Stream resolution and quality"))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 28)
        }
    }
}
