import Foundation
import Virtualization

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
@main struct ClipboardDeviceSmoke {
    @MainActor static func main() throws {
        let bridge = try ClipboardBridge()
        defer { bridge.stop() }
        let disk = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: CommandLine.arguments[1]), readOnly: true)
        _ = VZVirtioBlockDeviceConfiguration(attachment: disk)
        print("PASS: Apple console attachment and raw read-only guest-tools disk opened")
    }
}
