import Foundation
import Network
import NetworkExtension

/// Separate official DNS provider handles OS DNS UDP/TCP flows before applications connect to
/// resolved addresses. No IP->domain guessing, DNS cache flushing, certificate interception or relay.
final class SecureDNSProxyProvider: MDPIDNSProxyBase {
    private let queue = DispatchQueue(label: "io.macdpi.system-dns", qos: .utility)
    private var enabled = false
    private var generation = UUID()
    private var configuration = Configuration()
    private var encrypted: DNSHTTPTransport?
    private var control: MDPIControlServer?
    private var dnsObservation: NSKeyValueObservation?
    private var policy = DNSRoutingPolicy()
    private var tcp = [UUID: DNSStreamSession]()
    private var udp = [UUID: DNSDatagramSession]()
    private struct Opening { let flow: NEAppProxyFlow; let timer: DispatchSourceTimer }
    private var opening = [UUID: Opening]()
    private var stats = Snapshot()

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        let values = options ?? [:]
        queue.async { [self] in
            self.shutdown(stopControl: false); self.generation = UUID()
            guard let bytes = values["configuration"] as? Data,
                  let config = try? JSONDecoder().decode(Configuration.self, from: bytes),
                  (try? config.validated()) != nil, config.dnsMode == .cloudflare,
                  !config.allowLoopbackForTesting,
                  let team = MDPICopySigningTeam(),
                  let service = (Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any])?["NEMachServiceName"] as? String,
                  service == team + ".io.github.latryee.MacDPI.shared.DNSProxy" else { completionHandler(CoreError.invalidConfiguration); return }
            self.configuration = config
            guard self.updatePolicy() else { completionHandler(CoreError.invalidConfiguration); return }
            self.encrypted = DNSHTTPTransport()
            if self.control == nil {
                let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"io.github.latryee.MacDPI\""
                self.control = MDPIControlServer(service: service, requiredPeer: requirement, queue: self.queue) { [weak self] request, reply in
                    guard let self else { reply(Data()); return }
                    if request == Data("status".utf8) { reply(self.status()) }
                    else if request == Data("stop".utf8) { self.shutdown(stopControl: false); reply(self.status()) }
                    else { reply(Data()) }
                }
            }
            guard self.control?.start() == true else { self.shutdown(stopControl: true); completionHandler(CoreError.connectionFailed); return }
            self.dnsObservation = self.observe(\.systemDNSSettings, options: [.new]) { [weak self] _, _ in
                self?.queue.async { [weak self] in
                    guard let self, self.enabled else { return }
                    let previous = self.policy.originalResolverDomains
                    if !self.updatePolicy() {
                        self.shutdown(stopControl: false)
                        self.cancelProxyWithError(CoreError.invalidConfiguration as NSError)
                    } else if previous != self.policy.originalResolverDomains {
                        // Existing TCP DNS sessions hold a policy snapshot. Drop those flows and
                        // cancel pending work before accepting queries under the updated policy.
                        self.closeFlows()
                    }
                }
            }
            self.enabled = true; self.stats = Snapshot(); self.stats.state = .enabled; completionHandler(nil)
        }
    }
    private func updatePolicy() -> Bool {
        let settings = systemDNSSettings ?? []
        let domains = configuration.dnsBypassDomains + settings.flatMap { ($0.matchDomains ?? []) + ($0.searchDomains ?? []) + [$0.domainName].compactMap { $0 } }
        guard domains.count <= 128 else { return false }
        policy = DNSRoutingPolicy(originalResolverDomains: domains)
        return true
    }
    private func router(endpoint: DatagramEndpoint, flow: NEAppProxyFlow, tcp: Bool) -> DNSQueryRouter {
        let transport = encrypted
        return DNSQueryRouter(policy: policy, encrypted: { bytes, completion in
            guard let transport else { completion(.failure(.stopped)); return ResolutionTicket() }
            return transport.request(bytes, completion: completion)
        }, original: { bytes, completion in
            DNSOriginalExchange(queue: self.queue, endpoint: endpoint, flow: flow, tcp: tcp).start(bytes, completion: completion)
        })
    }
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let datagram = flow as? NEAppProxyUDPFlow { return acceptUDP(datagram, host: "", port: 53) }
        guard let stream = flow as? NEAppProxyTCPFlow, let endpoint = stream.remoteEndpoint as? NWHostEndpoint,
              endpoint.port == "53", !TransparentPolicy.ownIdentifiers.contains(flow.metaData.sourceAppSigningIdentifier) else { return false }
        return accept(flow) { [weak self] id in
            guard let self else { return }
            let session = DNSStreamSession(client: FlowStream(flow: stream, queue: self.queue), queue: self.queue,
                router: self.router(endpoint: .init(host: endpoint.hostname, port: 53), flow: flow, tcp: true), preserveOriginalInterface: flow.isBound, timeout: 30)
            self.tcp[id] = session; session.onFinish = { [weak self] error in self?.tcp.removeValue(forKey: id); self?.finished(error) }; session.start()
        }
    }
    override func acceptUDP(_ flow: NEAppProxyUDPFlow, host: String, port: UInt16) -> Bool {
        guard port == 53, !TransparentPolicy.ownIdentifiers.contains(flow.metaData.sourceAppSigningIdentifier) else { return false }
        return accept(flow) { [weak self] id in
            guard let self else { return }
            let session = DNSDatagramSession(flow: FlowDatagrams(flow: flow, queue: self.queue), queue: self.queue,
                preserveOriginalInterface: flow.isBound, timeout: 30, makeRouter: { self.router(endpoint: $0, flow: flow, tcp: false) })
            self.udp[id] = session; session.onFinish = { [weak self] error in self?.udp.removeValue(forKey: id); self?.finished(error) }; session.start()
        }
    }
    private func accept(_ flow: NEAppProxyFlow, opened: @escaping (UUID) -> Void) -> Bool {
        queue.sync {
            guard enabled, tcp.count + udp.count + opening.count < min(64, configuration.maxConnections) else { return false }
            let id = UUID(), run = generation, timer = DispatchSource.makeTimerSource(queue: queue)
            opening[id] = Opening(flow: flow, timer: timer)
            timer.setEventHandler { [weak self] in
                guard let self, let item = self.opening.removeValue(forKey: id) else { return }
                item.timer.cancel(); item.flow.closeReadWithError(CoreError.timedOut as NSError); item.flow.closeWriteWithError(CoreError.timedOut as NSError); self.finished(.timedOut)
            }
            timer.schedule(deadline: .now() + 10); timer.resume()
            flow.open(withLocalEndpoint: nil) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard let pending = self.opening.removeValue(forKey: id) else { return }; pending.timer.cancel()
                    guard self.enabled, self.generation == run, error == nil else { flow.closeReadWithError(error); flow.closeWriteWithError(error); return }
                    self.stats.accepted &+= 1; opened(id); self.stats.activeConnections = self.tcp.count + self.udp.count
                }
            }
            return true
        }
    }
    private func finished(_ error: CoreError?) { stats.activeConnections = tcp.count + udp.count; if let error { stats.failures &+= 1; stats.lastError = error.rawValue } }
    private func status() -> Data { (try? JSONEncoder().encode(ProviderStatusMessage(isEnabled: enabled, activeTCPFlows: tcp.count, activeUDPFlows: udp.count, pendingFlows: opening.count, snapshot: stats))) ?? Data() }
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) { queue.async { self.shutdown(stopControl: true); completionHandler() } }
    private func closeFlows() {
        let pending = Array(opening.values); opening.removeAll(); pending.forEach { $0.timer.cancel(); $0.flow.closeReadWithError(nil); $0.flow.closeWriteWithError(nil) }
        Array(tcp.values).forEach { $0.stop() }; Array(udp.values).forEach { $0.stop() }; tcp.removeAll(); udp.removeAll()
        stats.activeConnections = 0
    }
    private func shutdown(stopControl: Bool) {
        enabled = false; generation = UUID(); dnsObservation?.invalidate(); dnsObservation = nil
        closeFlows()
        encrypted?.shutdown(); encrypted = nil; stats.state = .disabled; stats.activeConnections = 0
        if stopControl { control?.invalidate(); control = nil }
    }
}
