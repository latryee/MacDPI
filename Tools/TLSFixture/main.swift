// Isolated test server only. Never imports a key or trust anchor into the user's keychain.
import Foundation
import Network
import Security
import Darwin

guard #available(macOS 15, *) else { fputs("Memory-only TLS fixtures require macOS 15+\n", stderr); exit(2) }
guard CommandLine.arguments.count == 3, let port = UInt16(CommandLine.arguments[1]), port >= 1024 else { exit(2) }
let identityData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
var items: CFArray?
let options = [kSecImportExportPassphrase: "macdpi-fixture", kSecImportToMemoryOnly: true] as CFDictionary
let status = SecPKCS12Import(identityData as CFData, options, &items)
guard status == errSecSuccess, let item = (items as? [[String: Any]])?.first, let identityValue = item[kSecImportItemIdentity as String] else {
    fputs("Memory-only fixture identity failed: \(status)\n", stderr); exit(1)
}
let identity = identityValue as! SecIdentity
let tls = NWProtocolTLS.Options()
sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
let listener = try NWListener(using: parameters)
var active = [UUID: NWConnection]()
listener.newConnectionHandler = { connection in
    let id = UUID(); active[id] = connection
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard data != nil else { connection.cancel(); active.removeValue(forKey: id); return }
                let response = Data("HTTP/1.0 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nMacDPI!".utf8)
                connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.stateUpdateHandler = nil; connection.cancel(); active.removeValue(forKey: id)
                })
            }
        case .failed, .cancelled:
            connection.stateUpdateHandler = nil; connection.cancel(); active.removeValue(forKey: id)
        default: break
        }
    }
    connection.start(queue: .main)
}
listener.stateUpdateHandler = { state in
    if case .ready = state { print("READY"); fflush(stdout) }
    if case .failed = state { exit(1) }
}
listener.start(queue: .main)
dispatchMain()
