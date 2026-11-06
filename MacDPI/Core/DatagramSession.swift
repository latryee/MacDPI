import Foundation
import Network

/// An exact UDP destination. Transparent UDP never guesses a hostname from an IP address.
public struct DatagramEndpoint: Hashable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }

    var canonicalNumeric: DatagramEndpoint? {
        guard !host.contains("%"), port != 0,
              let numeric = IPv4Address(host)?.debugDescription ?? IPv6Address(host)?.debugDescription else { return nil }
        return DatagramEndpoint(host: numeric, port: port)
    }
    public func validated(allowLoopback: Bool = false) throws -> DatagramEndpoint {
        guard let numeric = canonicalNumeric, DestinationPolicy.permits(numeric.host, allowLoopback: allowLoopback) else {
            throw CoreError.forbiddenDestination
        }
        return numeric
    }
}

public struct Datagram: Sendable {
    public let data: Data
    /// Destination on source reads; original remote source on writes back to the application.
    public let endpoint: DatagramEndpoint
    public init(data: Data, endpoint: DatagramEndpoint) { self.data = data; self.endpoint = endpoint }
}

/// All callbacks must be delivered on the session's owning queue. One receive may be pending.
/// An empty batch means the source flow closed. A batch containing Data() is a valid empty datagram.
public protocol DatagramFlow: AnyObject {
    func receive(_ completion: @escaping (Result<[Datagram], CoreError>) -> Void)
    func send(_ datagram: Datagram, completion: @escaping (Error?) -> Void)
    func cancel()
}

/// A connected UDP transport for exactly one pinned numeric endpoint, with no upstream relay.
/// After start, every callback runs on that queue. A successful send means accepted locally,
/// not delivery to the remote application; UDP has no transport acknowledgement.
public protocol DatagramTransport: AnyObject {
    func start(queue: DispatchQueue, completion: @escaping (Result<Void, CoreError>) -> Void)
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void)
    func cancel()
}

public struct DatagramConfiguration: Equatable, Sendable {
    /// Conservative ordinary IPv4/IPv6 UDP payload bound. Jumbograms are not supported.
    public var maximumDatagramSize = 65_507
    public var maximumEndpoints = 16
    public var maximumBatchCount = 32
    public var maximumBatchBytes = 262_144
    public var maximumReplyCount = 32
    public var maximumReplyBytes = 262_144
    public var connectTimeout: TimeInterval = 5
    public var idleTimeout: TimeInterval = 30
    /// Ordinary DNS is deliberately outside generic UDP interception. A separately approved
    /// DNS configuration handles it; do not hijack split-DNS or local resolvers here.
    public var excludedPorts: Set<UInt16> = [53]
    public var excludedEndpoints: Set<DatagramEndpoint> = []
    /// Used only by isolated fixtures; production integration must leave this false.
    public var allowLoopbackForTesting = false
    public init() {}
    public func validated() throws -> DatagramConfiguration {
        guard (1...65_507).contains(maximumDatagramSize), (1...64).contains(maximumEndpoints),
              (1...64).contains(maximumBatchCount), (1...64).contains(maximumReplyCount),
              maximumBatchBytes >= maximumDatagramSize, maximumBatchBytes <= 4_194_304,
              maximumReplyBytes >= maximumDatagramSize, maximumReplyBytes <= 4_194_304,
              connectTimeout.isFinite, (0.01...60).contains(connectTimeout),
              idleTimeout.isFinite, (0.01...3600).contains(idleTimeout),
              excludedPorts.count <= 128, excludedEndpoints.count <= 128,
              excludedEndpoints.allSatisfy({ $0.canonicalNumeric != nil }) else { throw CoreError.invalidConfiguration }
        return self
    }
}

/// Bounded, datagram-preserving forwarding for one OS-supplied UDP flow. This creates no listener
/// and offers no network-accessible relay. It does not apply TLS transformations or claim UDP/QUIC
/// circumvention. All methods, state and callbacks are confined to the supplied serial queue.
public final class DatagramSession {
    public typealias TransportFactory = (DatagramEndpoint) -> DatagramTransport
    private final class Peer {
        let transport: DatagramTransport
        var ready = false
        var deadline: DispatchWorkItem?
        init(_ transport: DatagramTransport) { self.transport = transport }
    }
    private struct Reply { let datagram: Datagram; let peer: Peer }
    private let flow: DatagramFlow
    private let queue: DispatchQueue
    private let configuration: DatagramConfiguration
    private let makeTransport: TransportFactory
    private var peers = [DatagramEndpoint: Peer]()
    private var excludedEndpoints = Set<DatagramEndpoint>()
    private var batch = [Datagram]()
    private var batchIndex = 0
    private var replies = [Reply]()
    private var replyBytes = 0
    private var writingReply = false
    private var started = false
    private var closed = false
    private var timer: DispatchSourceTimer?
    public var onFinish: ((CoreError?) -> Void)?
    public var onTraffic: ((Int, Int) -> Void)?

    public init(flow: DatagramFlow, queue: DispatchQueue, configuration: DatagramConfiguration = DatagramConfiguration(),
                makeTransport: @escaping TransportFactory = { UDPTransport(endpoint: $0) }) {
        self.flow = flow; self.queue = queue; self.configuration = configuration; self.makeTransport = makeTransport
    }

    public func start() {
        guard !started, !closed else { return }
        started = true
        guard (try? configuration.validated()) != nil else { finish(.invalidConfiguration); return }
        excludedEndpoints = Set(configuration.excludedEndpoints.compactMap(\.canonicalNumeric))
        let source = DispatchSource.makeTimerSource(queue: queue)
        timer = source
        source.setEventHandler { [weak self] in self?.finish(.timedOut) }
        source.schedule(deadline: .now() + configuration.idleTimeout); source.resume()
        readSource()
    }

    private func readSource() {
        guard !closed else { return }
        flow.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error): self.finish(error)
            case .success(let datagrams):
                guard !datagrams.isEmpty else { self.finish(nil); return }
                guard datagrams.count <= self.configuration.maximumBatchCount else { self.finish(.capacity); return }
                var bytes = 0, validated = [Datagram](), endpoints = Set(self.peers.keys)
                validated.reserveCapacity(datagrams.count)
                for datagram in datagrams {
                    guard datagram.data.count <= self.configuration.maximumDatagramSize,
                          datagram.data.count <= self.configuration.maximumBatchBytes - bytes else { self.finish(.capacity); return }
                    bytes += datagram.data.count
                    guard let endpoint = try? datagram.endpoint.validated(allowLoopback: self.configuration.allowLoopbackForTesting),
                          !self.configuration.excludedPorts.contains(endpoint.port),
                          !self.excludedEndpoints.contains(endpoint) else { self.finish(.forbiddenDestination); return }
                    endpoints.insert(endpoint)
                    guard endpoints.count <= self.configuration.maximumEndpoints else { self.finish(.capacity); return }
                    validated.append(Datagram(data: datagram.data, endpoint: endpoint))
                }
                self.batch = validated; self.batchIndex = 0
                self.forwardNext()
            }
        }
    }

    private func forwardNext() {
        guard !closed else { return }
        guard batchIndex < batch.count else { batch.removeAll(keepingCapacity: false); readSource(); return }
        let datagram = batch[batchIndex], endpoint = datagram.endpoint
        if let peer = peers[endpoint] {
            guard peer.ready else { return }
            peer.transport.send(datagram.data) { [weak self, weak peer] error in
                guard let self, let peer, !self.closed, self.peers[endpoint] === peer else { return }
                guard error == nil else { self.finish(.connectionFailed); return }
                self.onTraffic?(datagram.data.count, 0); self.touch()
                self.batchIndex += 1; self.forwardNext()
            }
            return
        }
        let peer = Peer(makeTransport(endpoint)); peers[endpoint] = peer
        let deadline = DispatchWorkItem { [weak self, weak peer] in
            guard let self, let peer, !self.closed, self.peers[endpoint] === peer, !peer.ready else { return }
            self.finish(.timedOut)
        }
        peer.deadline = deadline; queue.asyncAfter(deadline: .now() + configuration.connectTimeout, execute: deadline)
        peer.transport.start(queue: queue) { [weak self, weak peer] result in
            guard let self, let peer, !self.closed, self.peers[endpoint] === peer else { return }
            switch result {
            case .failure(let error): self.finish(error)
            case .success:
                guard !peer.ready else { return }
                peer.ready = true; peer.deadline?.cancel(); peer.deadline = nil
                self.forwardNext(); self.readPeer(peer, endpoint: endpoint)
            }
        }
    }

    private func readPeer(_ peer: Peer, endpoint: DatagramEndpoint) {
        guard !closed, peers[endpoint] === peer else { return }
        peer.transport.receive { [weak self, weak peer] data, complete, error in
            guard let self, let peer, !self.closed, self.peers[endpoint] === peer else { return }
            guard error == nil else { self.finish(.connectionFailed); return }
            // nil + complete represents an empty message for transports that omit empty Data.
            let payload = data ?? Data()
            guard complete, payload.count <= self.configuration.maximumDatagramSize else { self.finish(.capacity); return }
            guard self.replies.count < self.configuration.maximumReplyCount,
                  payload.count <= self.configuration.maximumReplyBytes - self.replyBytes else { self.finish(.capacity); return }
            self.replies.append(Reply(datagram: Datagram(data: payload, endpoint: endpoint), peer: peer))
            self.replyBytes += payload.count
            // Each peer pauses reads until its own reply has drained to the source flow.
            self.writeReply()
        }
    }

    private func writeReply() {
        guard !closed, !writingReply, let first = replies.first else { return }
        writingReply = true
        flow.send(first.datagram) { [weak self, weak peer = first.peer] error in
            guard let self, let peer, !self.closed else { return }
            guard error == nil else { self.finish(.connectionFailed); return }
            self.replyBytes -= first.datagram.data.count
            self.replies.removeFirst(); self.writingReply = false
            self.onTraffic?(0, first.datagram.data.count); self.touch()
            self.readPeer(peer, endpoint: first.datagram.endpoint)
            self.writeReply()
        }
    }

    private func touch() { timer?.schedule(deadline: .now() + configuration.idleTimeout) }
    public func stop() { finish(nil) }
    private func finish(_ error: CoreError?) {
        guard !closed else { return }
        closed = true
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        let transports = Array(peers.values)
        peers.removeAll(); batch.removeAll(); replies.removeAll(); replyBytes = 0
        for peer in transports { peer.deadline?.cancel(); peer.transport.cancel() }
        flow.cancel()
        let callback = onFinish; onFinish = nil; onTraffic = nil; callback?(error)
    }
    deinit {
        if !closed {
            timer?.cancel(); peers.values.forEach { $0.deadline?.cancel(); $0.transport.cancel() }; flow.cancel()
        }
    }
}
