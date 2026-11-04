import Foundation
import Network
import NetworkExtension

/// Prepared integration: compile-only until signed, approved, and tested on a dedicated Mac.
final class FlowStream: ByteStream {
    let flow: NEAppProxyTCPFlow
    let queue: DispatchQueue
    init(flow: NEAppProxyTCPFlow, queue: DispatchQueue) { self.flow = flow; self.queue = queue }
    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void) {
        flow.readData { [weak self] data, error in
            guard let self else { return }
            self.queue.async {
                guard (data?.count ?? 0) <= TCPStream.maximumRead else { completion(nil, false, CoreError.capacity); return }
                completion(data, data?.isEmpty ?? true, error)
            }
        }
    }
    func send(_ data: Data, final: Bool, completion: @escaping (Error?) -> Void) {
        if data.isEmpty {
            if final { flow.closeWriteWithError(nil) }
            completion(nil); return
        }
        flow.write(data) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if final { self.flow.closeWriteWithError(error) }
                completion(error)
            }
        }
    }
    func cancel() { flow.closeReadWithError(nil); flow.closeWriteWithError(nil) }
}

final class TransparentProxyProvider: NETransparentProxyProvider {
    private let queue = DispatchQueue(label: "io.macdpi.transparent")
    private var resolver: HostResolving = SystemResolver()
    private var enabled = false
    private var generation = UUID()
    private var sessions = [UUID: ProxySession]()
    private var opening = [UUID: NEAppProxyTCPFlow]()
    private var configuration = Configuration()

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        let values = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        var config = Configuration()
        if let profile = values?["profile"] as? String, let parsed = Profile(rawValue: profile) { config.profile = parsed }
        if let offset = values?["splitOffset"] as? Int { config.splitOffset = offset }
        if let dns = values?["dnsMode"] as? String, let mode = DNSMode(rawValue: dns) { config.dnsMode = mode }
        do { _ = try config.validated() } catch { completionHandler(error); return }
        let run = queue.sync { () -> UUID in generation = UUID(); enabled = false; return generation }
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // Apple permits wildcard address rules with a specific non-DNS port. UDP is never claimed.
        settings.includedNetworkRules = ["0.0.0.0", "::"].map {
            NENetworkRule(remoteNetwork: NWHostEndpoint(hostname: $0, port: "443"), remotePrefix: 0,
                          localNetwork: nil, localPrefix: 0, protocol: .TCP, direction: .outbound)
        }
        settings.excludedNetworkRules = [("10.0.0.0", 8), ("127.0.0.0", 8), ("172.16.0.0", 12),
                                         ("192.168.0.0", 16), ("169.254.0.0", 16), ("::1", 128),
                                         ("fc00::", 7), ("fe80::", 10)].map {
            NENetworkRule(remoteNetwork: NWHostEndpoint(hostname: $0.0, port: "0"), remotePrefix: $0.1,
                          localNetwork: nil, localPrefix: 0, protocol: .TCP, direction: .outbound)
        }
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { completionHandler(CoreError.stopped); return }
            self.queue.async {
                guard self.generation == run else { completionHandler(CoreError.stopped); return }
                if error == nil {
                    self.resolver.shutdown()
                    self.resolver = config.dnsMode == .cloudflare ? HTTPSResolver() : SystemResolver()
                    self.configuration = config; self.enabled = true
                }
                completionHandler(error)
            }
        }
    }
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcp = flow as? NEAppProxyTCPFlow,
              let remote = tcp.remoteEndpoint as? NWHostEndpoint, let port = UInt16(remote.port), port == 443 else { return false }
        // Prefer the OS-provided hostname when available: the endpoint may already contain a sinkhole IP.
        // A missing hostname cannot be reconstructed reliably from encrypted application traffic.
        let host = tcp.remoteHostname ?? remote.hostname
        // Local/private literal traffic is left with the original stack. Named flows are validated after DNS.
        if (IPv4Address(remote.hostname) != nil || IPv6Address(remote.hostname) != nil),
           !DestinationPolicy.permits(remote.hostname) { return false }
        return queue.sync {
            guard enabled, sessions.count + opening.count < configuration.maxConnections else { return false }
            let id = UUID()
            opening[id] = tcp
            // Open has its own deadline; a delayed callback cannot resurrect a stopped/expired flow.
            queue.asyncAfter(deadline: .now() + configuration.handshakeTimeout) { [weak self] in
                guard let flow = self?.opening.removeValue(forKey: id) else { return }
                flow.closeReadWithError(CoreError.timedOut as NSError); flow.closeWriteWithError(CoreError.timedOut as NSError)
            }
            tcp.open(withLocalEndpoint: nil) { [weak self] error in
                guard let self else { return }
                self.queue.async { [self] in
                    guard self.opening.removeValue(forKey: id) != nil else { return }
                    guard self.enabled, error == nil else {
                        tcp.closeReadWithError(error); tcp.closeWriteWithError(error); return
                    }
                    let session = ProxySession(client: FlowStream(flow: tcp, queue: self.queue), queue: self.queue,
                                               configuration: self.configuration, resolver: self.resolver)
                    self.sessions[id] = session
                    session.onFinish = { [weak self] _ in self?.sessions.removeValue(forKey: id) }
                    session.start(destination: (host, port))
                }
            }
            return true
        }
    }
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async { self.shutdown(); completionHandler() }
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        // Fixed command vocabulary, no traffic or host metadata returned.
        queue.async {
            if messageData == Data("stop".utf8) { self.shutdown(); completionHandler?(Data("stopped".utf8)) }
            else { completionHandler?(Data((self.enabled ? "enabled" : "disabled").utf8)) }
        }
    }
    private func shutdown() {
        enabled = false; generation = UUID()
        let pending = Array(opening.values); opening.removeAll()
        pending.forEach { $0.closeReadWithError(nil); $0.closeWriteWithError(nil) }
        Array(sessions.values).forEach { $0.stop() }; sessions.removeAll()
        resolver.shutdown()
    }
}
