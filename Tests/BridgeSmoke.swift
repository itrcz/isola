import Foundation
import Virtualization

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
@main struct BridgeSmoke {
    @MainActor static func main() async throws {
        let bridge = try NetworkBridge()
        let attachment = try await bridge.start(ProxySettings(Host: "127.0.0.1", Port: 1, Username: "test", Password: "test"))
        guard attachment.maximumTransmissionUnit == 1500, bridge.process.isRunning, bridge.handle != nil else { fatalError("bridge not ready") }
        bridge.stop()
        guard !bridge.process.isRunning else { fatalError("orphan helper") }
        print("PASS: Swift launches gateway, connects UNIX sockets, creates VZ attachment and cleans up")
    }
}
