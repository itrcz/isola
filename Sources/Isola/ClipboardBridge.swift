import Foundation
import Virtualization
import Darwin

@MainActor final class ClipboardBridge: NSObject, VZVirtioConsoleDeviceDelegate {
    private var guestPortOpen = false
    private weak var console: VZVirtioConsoleDevice?
    private let endpoint: ClipboardEndpoint
    private let guestHandle: FileHandle
    let device: VZVirtioConsoleDeviceConfiguration
    init(clipboardEnabled: Bool = true, syncKeyboard: Bool = true, preventSleep: Bool = false, optimizePerformance: Bool = false, onPerformanceStatus: ((String) -> Void)? = nil, onSleepStatus: ((String) -> Void)? = nil, onToolsVersion: ((Int?) -> Void)? = nil, onStatus: ((String) -> Void)? = nil, onKeyboardStatus: ((String) -> Void)? = nil) throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw AppError.message("Не удалось создать канал буфера обмена.") }
        for fd in sockets { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        guestHandle = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        endpoint = ClipboardEndpoint(fd: sockets[1], host: true, clipboardEnabled: clipboardEnabled, syncKeyboard: syncKeyboard)
        endpoint.optimizePerformance = optimizePerformance; endpoint.onPerformanceStatus = onPerformanceStatus
        endpoint.preventSleep = preventSleep; endpoint.onSleepStatus = onSleepStatus
        endpoint.onToolsVersion = onToolsVersion
        endpoint.onStatus = onStatus; endpoint.onKeyboardStatus = onKeyboardStatus
        let port = VZVirtioConsolePortConfiguration()
        port.name = "org.isola.clipboard"
        port.isConsole = false
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: guestHandle, fileHandleForWriting: guestHandle)
        device = VZVirtioConsoleDeviceConfiguration(); device.ports[0] = port
        super.init()
        endpoint.start()
    }
    func bind(to vm: VZVirtualMachine) {
        console = vm.consoleDevices.first as? VZVirtioConsoleDevice
        console?.delegate = self
    }
    func reconnect() { console?.ports[0]?.attachment = device.ports[0]?.attachment }
    func disconnectForSuspend() async throws {
        // A virtio port disconnect gives the guest helper EOF. Wait for its fd
        // to close, so no half clipboard frame survives into the saved state.
        console?.ports[0]?.attachment = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while guestPortOpen {
            guard ContinuousClock.now < deadline else {
                reconnect()
                throw AppError.message(L("Isola Tools не закрыл канал. Повтори паузу после завершения копирования или обнови Tools.", "Isola Tools did not close its channel. Retry after copying finishes or update Tools."))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    nonisolated func consoleDevice(_ consoleDevice: VZVirtioConsoleDevice, didOpen consolePort: VZVirtioConsolePort) {
        Task { @MainActor in self.guestPortOpen = true }
    }
    nonisolated func consoleDevice(_ consoleDevice: VZVirtioConsoleDevice, didClose consolePort: VZVirtioConsolePort) {
        Task { @MainActor in self.guestPortOpen = false }
    }
    func setPerformance(_ enabled: Bool) { endpoint.setPerformance(enabled) }
    func setPreventSleep(_ enabled: Bool) { endpoint.setPreventSleep(enabled) }
    func publishKeyboard() { endpoint.publishInputSource() }
    func setRemoteRelay(_ relay: ((ClipboardMessage) -> Void)?) { endpoint.setRemoteRelay(relay) }
    func receiveRemote(_ message: ClipboardMessage) { endpoint.receiveRemote(message) }
    func stop() { endpoint.stop(); try? guestHandle.close() }
}
