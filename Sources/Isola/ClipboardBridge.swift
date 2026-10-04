import Foundation
import Virtualization
import Darwin

@MainActor final class ClipboardBridge {
    private let endpoint: ClipboardEndpoint
    private let guestHandle: FileHandle
    let device: VZVirtioConsoleDeviceConfiguration
    init(clipboardEnabled: Bool = true, syncKeyboard: Bool = true, desktop: Bool = false, downloads: Bool = false, optimizePerformance: Bool = false, onPerformanceStatus: ((String) -> Void)? = nil, onStatus: ((String) -> Void)? = nil, onKeyboardStatus: ((String) -> Void)? = nil) throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw AppError.message("Не удалось создать канал буфера обмена.") }
        for fd in sockets { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        guestHandle = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        endpoint = ClipboardEndpoint(fd: sockets[1], host: true, clipboardEnabled: clipboardEnabled, syncKeyboard: syncKeyboard)
        endpoint.optimizePerformance = optimizePerformance; endpoint.onPerformanceStatus = onPerformanceStatus
        endpoint.mirrorDesktop = desktop; endpoint.mirrorDownloads = downloads
        endpoint.onStatus = onStatus; endpoint.onKeyboardStatus = onKeyboardStatus
        let port = VZVirtioConsolePortConfiguration()
        port.name = "org.isola.clipboard"
        port.isConsole = false
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: guestHandle, fileHandleForWriting: guestHandle)
        device = VZVirtioConsoleDeviceConfiguration(); device.ports[0] = port
        endpoint.start()
    }
    func setPerformance(_ enabled: Bool) { endpoint.setPerformance(enabled) }
    func publishKeyboard() { endpoint.publishInputSource() }
    func stop() { endpoint.stop(); try? guestHandle.close() }
}
