import Foundation
import Network
import Security
import AppKit

@main struct RemoteNetworkSmoke {
    @MainActor static func main() throws {
        func until(_ condition: () -> Bool, timeout: Double = 12) {
            let end = Date().addingTimeInterval(timeout)
            while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            precondition(condition(), "network test timed out")
        }
        for password in [nil, "проверка TLS пароль"] as [String?] {
            let listener = try NWListener(using: RemoteSecurity.parameters(password: password), on: .any)
            var server: RemoteLink?, client: RemoteLink?
            var port: NWEndpoint.Port?, reply: RemotePacket?, serverReady = false
            listener.stateUpdateHandler = { state in if case .ready = state { DispatchQueue.main.async { port = listener.port } } }
            listener.newConnectionHandler = { connection in
                precondition(RemoteLAN.allows(connection.endpoint))
                let link = RemoteLink(connection)
                link.onReady = {
                    let metadata = (connection.metadata(definition: NWProtocolTLS.definition) as! NWProtocolTLS.Metadata).securityProtocolMetadata
                    precondition(sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata) == .TLSv12)
                    precondition(sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata).rawValue == 0xCCAC)
                    DispatchQueue.main.async { serverReady = true }
                }
                link.onPacket = { packet, consumed in link.send(packet, completion: consumed) }
                DispatchQueue.main.async { server = link }
                link.start()
            }
            listener.start(queue: .main); until { port != nil }
            client = RemoteLink(NWConnection(host: "127.0.0.1", port: port!, using: try RemoteSecurity.parameters(password: password)))
            client!.onReady = { client?.send(RemotePacket(kind: "clipboard", clipboard: ClipboardMessage(kind: "clipboard", files: [ClipboardFile(name: "binary.bin", data: Data(repeating: 0xA5, count: 2 * 1024 * 1024))]))) }
            client!.onPacket = { packet, consumed in DispatchQueue.main.async { reply = packet; consumed() } }
            client!.start(); until { reply != nil }
            precondition(serverReady && reply?.clipboard?.files?.first?.data == Data(repeating: 0xA5, count: 2 * 1024 * 1024))
            client?.stop(); server?.stop(); listener.cancel(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let listener = try NWListener(using: RemoteSecurity.parameters(password: "correct"), on: .any)
        var port: NWEndpoint.Port?, server: RemoteLink?, unauthorizedData = false, closed = false
        listener.stateUpdateHandler = { state in if case .ready = state { DispatchQueue.main.async { port = listener.port } } }
        listener.newConnectionHandler = { connection in
            let link = RemoteLink(connection)
            link.onPacket = { _, consumed in DispatchQueue.main.async { unauthorizedData = true; consumed() } }
            DispatchQueue.main.async { server = link }; link.start()
        }
        listener.start(queue: .main); until { port != nil }
        let wrong = RemoteLink(NWConnection(host: "127.0.0.1", port: port!, using: try RemoteSecurity.parameters(password: "wrong")))
        wrong.onReady = { wrong.send(RemotePacket(kind: "hello", version: 1)) }
        wrong.onClose = { _ in DispatchQueue.main.async { closed = true } }; wrong.start()
        until { closed }; precondition(!unauthorizedData, "incorrect password delivered application data")
        wrong.stop(); server?.stop(); listener.cancel()
        for malformed in [Data([255, 255, 255, 255]), Data([0, 0, 0, 4, 1, 2, 3, 4])] {
            let listener = try NWListener(using: RemoteSecurity.parameters(password: nil), on: .any)
            var bound: NWEndpoint.Port?, receiver: RemoteLink?, rejected = false
            listener.stateUpdateHandler = { state in if case .ready = state { DispatchQueue.main.async { bound = listener.port } } }
            listener.newConnectionHandler = { connection in
                let link = RemoteLink(connection)
                link.onClose = { _ in DispatchQueue.main.async { rejected = true } }
                DispatchQueue.main.async { receiver = link }; link.start()
            }
            listener.start(queue: .main); until { bound != nil }
            let connection = NWConnection(host: "127.0.0.1", port: bound!, using: try RemoteSecurity.parameters(password: nil))
            let sender = RemoteLink(connection)
            sender.onReady = { connection.send(content: malformed, completion: .contentProcessed { _ in }) }; sender.start()
            until { rejected }; sender.stop(); receiver?.stop(); listener.cancel()
        }
        precondition(!RemoteLAN.allows(.hostPort(host: "8.8.8.8", port: 443)))
        precondition(!RemoteLAN.allows(.hostPort(host: "example.com", port: 443)))
        precondition(RemoteLAN.allows(.hostPort(host: "::1", port: 443)))
        print("PASS: TLS ECDHE-PSK open/password connections, binary file round trip, negotiated cipher verified, wrong password/malformed frames rejected, LAN peer guard")
    }
}
