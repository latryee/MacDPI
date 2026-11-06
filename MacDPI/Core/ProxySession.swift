import Foundation
import Network

/// All mutable state is confined to queue. One read per direction, next read only after send completion.
public final class ProxySession {
    private let client: ByteStream
    private let queue: DispatchQueue
    private let configuration: Configuration
    private let resolver: HostResolving
    private var upstream: OutboundByteStream?
    private let makeUpstream: (String, UInt16) -> OutboundByteStream
    private let authenticationToken: String?
    private var resolutionTicket: ResolutionTicket?
    private var timer: DispatchSourceTimer?
    private var header = Data()
    private var initial: InitialFlightProcessor
    private var closed = false
    private var clientEOF = false
    private var serverEOF = false
    private var clientDrained = false
    private var serverDrained = false
    private var tunnelling = false
    private var isHTTP = true
    private var initialCounted = false
    private var addresses = [String]()
    private var destinationPort: UInt16 = 443
    public var onFinish: ((CoreError?) -> Void)?
    public var onTraffic: ((Int, Int, Bool?, Bool) -> Void)?

    public init(client: ByteStream, queue: DispatchQueue, configuration: Configuration, resolver: HostResolving, authenticationToken: String? = nil,
                makeUpstream: @escaping (String, UInt16) -> OutboundByteStream = { host, port in
                    TCPStream(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: TCPStream.parameters()))
                }) {
        self.client = client; self.queue = queue; self.configuration = configuration; self.resolver = resolver
        self.makeUpstream = makeUpstream
        self.authenticationToken = authenticationToken
        initial = InitialFlightProcessor(configuration: configuration)
    }

    public func start(destination: (String, UInt16)? = nil) {
        isHTTP = destination == nil
        let source = DispatchSource.makeTimerSource(queue: queue)
        timer = source
        source.setEventHandler { [weak self] in self?.finish(.timedOut) }
        source.schedule(deadline: .now() + configuration.handshakeTimeout)
        source.resume()
        if let destination { resolve(host: destination.0, port: destination.1, prefix: Data(), isConnect: false) }
        else { readHeader() }
    }

    private func readHeader() {
        client.receive { [weak self] data, eof, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, !data.isEmpty else { self.finish(.invalidRequest); return }
            // At most one receive beyond the bounded header, including pipelined TLS bytes.
            self.header.append(data)
            do {
                guard let request = try ConnectRequest.parse(self.header, allowProxyAuthentication: self.authenticationToken != nil) else {
                    if eof { self.finish(.invalidRequest) } else { self.readHeader() }; return
                }
                if let token = self.authenticationToken, !LocalProxyAuthentication.accepts(header: request.proxyAuthorization, token: token) {
                    self.client.send(Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"MacDPI\"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8), final: false) { [weak self] _ in self?.finish(.forbiddenDestination) }
                    return
                }
                let prefix = Data(self.header.dropFirst(request.headerLength))
                self.header = Data()
                self.clientEOF = eof
                self.resolve(host: request.host, port: request.port, prefix: prefix, isConnect: true)
            } catch { self.reject(.invalidRequest, status: "400 Bad Request") }
        }
    }

    private func reject(_ error: CoreError, status: String) {
        guard isHTTP else { finish(error); return }
        client.send(Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8), final: false) { [weak self] _ in self?.finish(error) }
    }

    private func resolve(host: String, port: UInt16, prefix: Data, isConnect: Bool) {
        guard configuration.allowedPorts.contains(port) else { reject(.forbiddenDestination, status: "403 Forbidden"); return }
        destinationPort = port
        resolutionTicket = resolver.resolve(host) { [weak self] result in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.closed else { return }
                self.resolutionTicket = nil
                switch result {
                case .failure(let error): self.finish(error)
                case .success(let addresses):
                    self.addresses = addresses.filter { DestinationPolicy.permits($0, allowLoopback: self.configuration.allowLoopbackForTesting) }
                    guard !self.addresses.isEmpty else { self.reject(.forbiddenDestination, status: "403 Forbidden"); return }
                    self.connectNext(prefix: prefix, isConnect: isConnect)
                }
            }
        }
    }

    private func connectNext(prefix: Data, isConnect: Bool) {
        guard !closed else { return }
        guard !addresses.isEmpty else { finish(.connectionFailed); return }
        let address = addresses.removeFirst()
        let stream = makeUpstream(address, destinationPort)
        upstream = stream
        stream.start(queue: queue) { [weak self, weak stream] result in
            guard let self, let stream, !self.closed, self.upstream === stream else { return }
            switch result {
            case .success:
                self.tunnelling = true
                self.touch()
                let begin = { [weak self] in
                    guard let self, !self.closed else { return }
                    self.readServer()
                    if prefix.isEmpty && !self.clientEOF { self.readClient() }
                    else { self.forwardClient(prefix, eof: self.clientEOF) }
                }
                if isConnect {
                    self.client.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), final: false) { [weak self] error in
                        if error != nil { self?.finish(.connectionFailed) } else { begin() }
                    }
                } else { begin() }
            case .failure:
                self.upstream?.cancel(); self.upstream = nil
                self.connectNext(prefix: prefix, isConnect: isConnect)
            }
        }
    }

    private func readClient() {
        guard !closed else { return }
        client.receive { [weak self] data, eof, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.finish(.connectionFailed); return }
            self.forwardClient(data ?? Data(), eof: eof)
        }
    }

    private func forwardClient(_ data: Data, eof: Bool) {
        clientEOF = eof
        onTraffic?(data.count, 0, nil, false)
        guard let output = initial.consume(data, eof: eof) else { readClient(); return }
        let decision: Bool? = initialCounted ? nil : output.transformed
        initialCounted = true
        onTraffic?(0, 0, decision, false)
        touch()
        upstream?.send(output.data, final: eof) { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.finish(.connectionFailed); return }
            if eof { self.clientDrained = true; if self.serverDrained { self.finish(nil) } }
            else { self.readClient() }
        }
    }

    private func readServer() {
        upstream?.receive { [weak self] data, eof, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.finish(.connectionFailed); return }
            self.serverEOF = eof
            let bytes = data ?? Data()
            self.onTraffic?(0, bytes.count, nil, false)
            self.touch()
            self.client.send(bytes, final: eof) { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { self.finish(.connectionFailed); return }
                if eof { self.serverDrained = true; if self.clientDrained { self.finish(nil) } }
                else { self.readServer() }
            }
        }
    }

    private func touch() {
        if tunnelling && initial.decided { timer?.schedule(deadline: .now() + configuration.idleTimeout) }
    }

    public func stop() { finish(nil) }

    private func finish(_ error: CoreError?) {
        guard !closed else { return }
        closed = true
        resolutionTicket?.cancel(); resolutionTicket = nil
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        client.cancel(); upstream?.cancel(); upstream = nil
        header = Data(); addresses.removeAll()
        let callback = onFinish
        onFinish = nil; onTraffic = nil
        callback?(error)
    }

    deinit { resolutionTicket?.cancel(); timer?.cancel(); client.cancel(); upstream?.cancel() }
}
