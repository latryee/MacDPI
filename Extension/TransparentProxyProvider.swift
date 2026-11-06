import Foundation
import Network
import NetworkExtension

/// Official flow-based integration. Source compiled/fixture tested; OS interception is never
/// claimed verified until this signed provider has been explicitly approved and exercised.
final class TransparentProxyProvider: MDPITransparentProxyBase {
    private let queue = DispatchQueue(label: "io.macdpi.transparent", qos: .userInitiated)
    private let resolver = SystemResolver()
    private var configuration = Configuration()
    private var enabled = false
    private var sleeping = false
    private var generation = UUID()
    private var pendingStart: ((Error?) -> Void)?
    private var tcp = [UUID: ProxySession]()
    private var udp = [UUID: DatagramSession]()
    private struct Opening { let flow: NEAppProxyFlow; let timer: DispatchSourceTimer }
    private var opening = [UUID: Opening]()
    private var stats = Snapshot()

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        let values = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        queue.async { [self] in
            self.shutdown()
            self.generation = UUID(); let run = self.generation
            var config = Configuration()
            if let bytes = values["configuration"] as? Data, let parsed = try? JSONDecoder().decode(Configuration.self, from: bytes) { config = parsed }
            if let profile = values["profile"] as? String, let parsed = Profile(rawValue: profile) { config.profile = parsed }
            if let offset = values["splitOffset"] as? Int { config.splitOffset = offset }
            if let limit = values["maxConnections"] as? Int { config.maxConnections = limit }
            guard (try? config.validated()) != nil, !config.allowLoopbackForTesting else { completionHandler(CoreError.invalidConfiguration); return }
            self.configuration = config; self.pendingStart = completionHandler; self.sleeping = false
            let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            // No wildcard-address/port-0 endpoint is constructed. The public all-outbound rule
            // uses nil endpoints. DNS is deliberately declined by the admission policy below.
            settings.includedNetworkRules = [NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil, localPrefix: 0, protocol: .any, direction: .outbound)]
            // Apple rejects a wildcard address paired with port zero. The numeric admission
            // policy below already declines all of 0.0.0.0/8, so omit that exclusion rule.
            let networks: [(String, Int)] = [("10.0.0.0", 8), ("100.64.0.0", 10), ("127.0.0.0", 8),
                ("169.254.0.0", 16), ("172.16.0.0", 12), ("192.168.0.0", 16), ("224.0.0.0", 4),
                ("::1", 128), ("fc00::", 7), ("fe80::", 10), ("ff00::", 8)]
            settings.excludedNetworkRules = networks.map { NENetworkRule(remoteNetwork: NWHostEndpoint(hostname: $0.0, port: "0"), remotePrefix: $0.1, localNetwork: nil, localPrefix: 0, protocol: .any, direction: .outbound) }
            self.setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == run else { return }
                    self.enabled = error == nil; self.stats = Snapshot(); self.stats.state = error == nil ? .enabled : .failed
                    let callback = self.pendingStart; self.pendingStart = nil; callback?(error)
                }
            }
        }
    }
    private func permitted(_ flow: NEAppProxyFlow, host: String, port: UInt16) -> Bool {
        TransparentPolicy.shouldHandle(endpoint: .init(host: host, port: port), sourceIdentifier: flow.metaData.sourceAppSigningIdentifier,
                                       isBound: flow.isBound, hasInterface: flow.networkInterface != nil)
    }
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let stream = flow as? NEAppProxyTCPFlow, let endpoint = stream.remoteEndpoint as? NWHostEndpoint,
              let port = UInt16(endpoint.port), permitted(flow, host: endpoint.hostname, port: port) else { return false }
        return accept(flow) { [weak self] id in
            guard let self else { return }
            let config = TransparentPolicy.configuration(for: port, base: self.configuration)
            let session = ProxySession(client: FlowStream(flow: stream, queue: self.queue), queue: self.queue, configuration: config, resolver: self.resolver,
                                       makeUpstream: { host, port in NativeOutboundStream(host: host, port: port, flow: stream) })
            self.tcp[id] = session
            session.onTraffic = { [weak self] up, down, transformed, _ in self?.traffic(up: up, down: down, transformed: transformed) }
            session.onFinish = { [weak self] error in self?.tcp.removeValue(forKey: id); self?.finished(error) }
            // Preserve the actual numeric destination, including IP-only clients. DNS recovery
            // happens before application resolution in the separate approved DNS provider.
            session.start(destination: (endpoint.hostname, port))
        }
    }
    override func acceptUDP(_ flow: NEAppProxyUDPFlow, host: String, port: UInt16) -> Bool {
        guard permitted(flow, host: host, port: port) else { return false }
        return accept(flow) { [weak self] id in
            guard let self else { return }
            var settings = DatagramConfiguration(); settings.idleTimeout = min(120, self.configuration.idleTimeout)
            let interfaceIndex = flow.isBound ? flow.networkInterface.map { nw_interface_get_index($0) } : nil
            let session = DatagramSession(flow: FlowDatagrams(flow: flow, queue: self.queue), queue: self.queue, configuration: settings,
                                          makeTransport: { UDPTransport(endpoint: $0, interfaceIndex: interfaceIndex) })
            self.udp[id] = session
            session.onTraffic = { [weak self] up, down in self?.traffic(up: up, down: down, transformed: nil) }
            session.onFinish = { [weak self] error in self?.udp.removeValue(forKey: id); self?.finished(error) }
            session.start()
        }
    }
    private func accept(_ flow: NEAppProxyFlow, opened: @escaping (UUID) -> Void) -> Bool {
        queue.sync {
            guard enabled, !sleeping, tcp.count + udp.count + opening.count < configuration.maxConnections else { return false }
            let id = UUID(), run = generation, timer = DispatchSource.makeTimerSource(queue: queue)
            opening[id] = Opening(flow: flow, timer: timer)
            timer.setEventHandler { [weak self] in
                guard let self, let pending = self.opening.removeValue(forKey: id) else { return }
                pending.timer.cancel(); pending.flow.closeReadWithError(CoreError.timedOut as NSError); pending.flow.closeWriteWithError(CoreError.timedOut as NSError)
                self.finished(.timedOut)
            }
            timer.schedule(deadline: .now() + configuration.handshakeTimeout); timer.resume()
            flow.open(withLocalEndpoint: nil) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard let pending = self.opening.removeValue(forKey: id) else { return }; pending.timer.cancel()
                    guard self.enabled, self.generation == run, error == nil else {
                        flow.closeReadWithError(error); flow.closeWriteWithError(error); self.finished(error == nil ? nil : .connectionFailed); return
                    }
                    self.stats.accepted &+= 1; opened(id); self.stats.activeConnections = self.tcp.count + self.udp.count
                }
            }
            return true
        }
    }
    private func traffic(up: Int, down: Int, transformed: Bool?) {
        stats.uploaded &+= UInt64(up); stats.downloaded &+= UInt64(down)
        if let transformed { if transformed { stats.transformed &+= 1 } else { stats.passedThrough &+= 1 } }
    }
    private func finished(_ error: CoreError?) {
        stats.activeConnections = tcp.count + udp.count
        if let error { stats.failures &+= 1; stats.lastError = error.rawValue }
    }
    private func status() -> Data? {
        try? JSONEncoder().encode(ProviderStatusMessage(isEnabled: enabled, activeTCPFlows: tcp.count, activeUDPFlows: udp.count,
                                                      pendingFlows: opening.count, snapshot: stats))
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        queue.async {
            guard messageData.count <= 16 else { completionHandler?(nil); return }
            if messageData == Data("status".utf8) { completionHandler?(self.status()) }
            else if messageData == Data("stop".utf8) {
                self.shutdown()
                self.setTunnelNetworkSettings(nil) { _ in self.queue.async { completionHandler?(self.status()) } }
            } else { completionHandler?(nil) }
        }
    }
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) { queue.async { self.shutdown(); completionHandler() } }
    override func sleep(completionHandler: @escaping () -> Void) { queue.async { self.sleeping = true; self.closeFlows(); completionHandler() } }
    override func wake() { queue.async { self.sleeping = false } }
    private func closeFlows() {
        let pending = Array(opening.values); opening.removeAll()
        pending.forEach { $0.timer.cancel(); $0.flow.closeReadWithError(nil); $0.flow.closeWriteWithError(nil) }
        Array(tcp.values).forEach { $0.stop() }; Array(udp.values).forEach { $0.stop() }
        tcp.removeAll(); udp.removeAll(); stats.activeConnections = 0
    }
    private func shutdown() {
        enabled = false; generation = UUID(); closeFlows(); stats.state = .disabled
        let callback = pendingStart; pendingStart = nil; callback?(CoreError.stopped)
    }
}
