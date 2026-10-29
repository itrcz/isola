import Foundation
import Network

@main struct RemoteDiscoverySmoke {
    @MainActor static func main() throws {
        let discovery = RemoteDiscovery()
        let name = "Isola Discovery Test " + UUID().uuidString.prefix(8)
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        func publish(_ auth: String) {
            listener.service = NWListener.Service(name: name, type: RemoteSecurity.serviceType, domain: "local.", txtRecord: NWTXTRecord(["version": "1", "auth": auth]))
        }
        func until(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(8)
            while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            precondition(condition(), discovery.error ?? "Bonjour fixture not discovered")
        }
        publish("open"); listener.start(queue: .main); discovery.start()
        defer { listener.cancel(); discovery.stop() }
        until { discovery.peers.contains { $0.name == name && !$0.protected } }
        precondition(discovery.peers.filter { $0.name == name }.count == 1)
        publish("password")
        until { discovery.peers.contains { $0.name == name && $0.protected } }
        listener.cancel()
        until { !discovery.peers.contains { $0.name == name } }
        print("PASS: Bonjour discovery, open/password metadata changes, service removal")
    }
}
