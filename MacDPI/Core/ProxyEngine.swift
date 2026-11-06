import Foundation
import Network

public protocol EngineControlling: AnyObject {
    func start(configuration: Configuration, completion: @escaping (Result<Void, CoreError>) -> Void)
    func stop(completion: @escaping () -> Void)
    func snapshot(_ completion: @escaping (Snapshot) -> Void)
}

/// The queue owns listener, sessions and counters. Public operations enqueue, never block the UI.
public final class ProxyEngine: EngineControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.macdpi.engine", qos: .userInitiated)
    private let injectedResolver: HostResolving?
    private let authenticationToken: String?
    private var resolver: HostResolving?
    private var listener: NWListener?
    private var sessions = [UUID: ProxySession]()
    private var stats = Snapshot()
    private var configuration = Configuration()
    private var pendingStart: ((Result<Void, CoreError>) -> Void)?
    public init(authenticationToken: String? = nil, resolver: HostResolving? = nil) {
        self.authenticationToken = authenticationToken; injectedResolver = resolver
    }

    public func snapshot(_ completion: @escaping (Snapshot) -> Void) { queue.async { completion(self.stats) } }

    public func start(configuration: Configuration, completion: @escaping (Result<Void, CoreError>) -> Void) {
        queue.async { [self] in
            guard self.listener == nil else { completion(.failure(.invalidConfiguration)); return }
            do {
                self.configuration = try configuration.validated()
                if let token = authenticationToken {
                    guard (16...128).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw CoreError.invalidConfiguration }
                }
                self.resolver = self.injectedResolver ?? (configuration.dnsMode == .cloudflare ? HTTPSResolver() : SystemResolver())
                let parameters = TCPStream.parameters()
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: configuration.port)!)
                parameters.allowLocalEndpointReuse = false
                let listener = try NWListener(using: parameters)
                self.listener = listener; self.pendingStart = completion
                self.stats = Snapshot(); self.stats.state = .starting
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.stats.state = .enabled
                        let callback = self.pendingStart; self.pendingStart = nil
                        callback?(.success(()))
                    case .failed, .waiting:
                        let callback = self.pendingStart; self.pendingStart = nil; callback?(.failure(.connectionFailed))
                        self.shutdown()
                        self.stats.state = .failed; self.stats.lastError = "Listener unavailable. Check whether the port is already in use."
                    default: break
                    }
                }
                listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + configuration.handshakeTimeout) { [weak self, weak listener] in
                    guard let self, let listener, self.listener === listener, self.pendingStart != nil else { return }
                    self.shutdown(); self.stats.state = .failed; self.stats.lastError = CoreError.timedOut.rawValue
                }
            } catch {
                self.resolver?.shutdown(); self.resolver = nil
                self.stats.state = .failed; self.stats.lastError = error.localizedDescription
                completion(.failure(.invalidConfiguration))
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard stats.state == .enabled, sessions.count < configuration.maxConnections, let resolver else {
            stats.rejected &+= 1; connection.cancel(); return
        }
        let id = UUID()
        let session = ProxySession(client: TCPStream(connection), queue: queue, configuration: configuration, resolver: resolver, authenticationToken: authenticationToken)
        sessions[id] = session; stats.activeConnections = sessions.count; stats.accepted &+= 1
        session.onTraffic = { [weak self] up, down, transformed, _ in
            guard let self else { return }
            self.stats.uploaded &+= UInt64(up); self.stats.downloaded &+= UInt64(down)
            if let transformed {
                if transformed { self.stats.transformed &+= 1 } else { self.stats.passedThrough &+= 1 }
            }
        }
        session.onFinish = { [weak self] error in
            guard let self else { return }
            self.sessions.removeValue(forKey: id); self.stats.activeConnections = self.sessions.count
            if let error { self.stats.failures &+= 1; self.stats.lastError = error.localizedDescription }
        }
        connection.start(queue: queue)
        session.start()
    }

    public func stop(completion: @escaping () -> Void = {}) {
        queue.async { self.shutdown(); self.stats.state = .disabled; completion() }
    }

    private func shutdown() {
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let pending = pendingStart; pendingStart = nil; pending?(.failure(.stopped))
        let active = Array(sessions.values)
        active.forEach { $0.stop() }
        resolver?.shutdown(); resolver = nil
        sessions.removeAll(); stats.activeConnections = 0
    }

    deinit {
        // Lifetime owners must await stop before releasing. This also closes a forgotten listener.
        listener?.cancel()
        resolver?.shutdown()
    }
}
