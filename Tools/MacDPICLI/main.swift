import Foundation
import MacDPICore
import Darwin

var configuration = Configuration()
var duration: Double?
var args = Array(CommandLine.arguments.dropFirst())
func value() -> String {
    guard !args.isEmpty else { fputs("Missing option value\n", stderr); exit(2) }
    return args.removeFirst()
}
while !args.isEmpty {
    switch args.removeFirst() {
    case "--port": guard let n = UInt16(value()) else { exit(2) }; configuration.port = n
    case "--profile": guard let p = Profile(rawValue: value()) else { exit(2) }; configuration.profile = p
    case "--dns": guard let mode = DNSMode(rawValue: value()) else { exit(2) }; configuration.dnsMode = mode
    case "--split-offset": guard let n = Int(value()) else { exit(2) }; configuration.splitOffset = n
    case "--max-connections": guard let n = Int(value()) else { exit(2) }; configuration.maxConnections = n
    case "--handshake-timeout": guard let n = Double(value()) else { exit(2) }; configuration.handshakeTimeout = n
    case "--idle-timeout": guard let n = Double(value()) else { exit(2) }; configuration.idleTimeout = n
    case "--allow-loopback-testing": configuration.allowLoopbackForTesting = true
    case "--destination-port": guard let n = UInt16(value()) else { exit(2) }; configuration.allowedPorts = [n]
    case "--duration": guard let n = Double(value()), n.isFinite, (1...3600).contains(n) else { exit(2) }; duration = n
    case "--help":
        print("macdpi [--port 8080] [--profile standard|compatibility|advanced] [--dns system|cloudflare] [--split-offset 32] [--duration seconds]\nCloudflare DNS is opt-in and sends destination names to Cloudflare over HTTPS.\nIsolated fixtures only: --allow-loopback-testing --destination-port PORT\nBinds to IPv4 loopback only. No system settings are changed.")
        exit(0)
    default: fputs("Unknown option. Use --help.\n", stderr); exit(2)
    }
}
do { _ = try configuration.validated() } catch { fputs("Invalid configuration\n", stderr); exit(2) }
let engine = ProxyEngine()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
func stop() {
    engine.stop {
        engine.snapshot { snapshot in
            if let data = try? encoder.encode(snapshot) { print(String(decoding: data, as: UTF8.self)) }
            exit(0)
        }
    }
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { stop() }; interrupt.resume()
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { stop() }; terminate.resume()
engine.start(configuration: configuration) { result in
    switch result {
    case .success:
        print("READY 127.0.0.1:\(configuration.port) \(configuration.profile.rawValue)")
        fflush(stdout)
    case .failure(let error): fputs("\(error.localizedDescription)\n", stderr); exit(1)
    }
}
if let duration { DispatchQueue.main.asyncAfter(deadline: .now() + duration) { stop() } }
dispatchMain()
