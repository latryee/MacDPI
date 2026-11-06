import Foundation

/// DNS TCP framing, pipelining and cancellation without terminating or decrypting application TLS.
public final class DNSStreamSession {
    private let client: ByteStream
    private let queue: DispatchQueue
    private let router: DNSQueryRouter
    private let preserveOriginal: Bool
    private let timeout: TimeInterval
    private var framer = DNSStreamFramer()
    private var timer: DispatchSourceTimer?
    private var ticket: ResolutionTicket?
    private var eof = false
    private var closed = false
    private var started = false
    public var onFinish: ((CoreError?) -> Void)?
    public init(client: ByteStream, queue: DispatchQueue, router: DNSQueryRouter, preserveOriginalInterface: Bool = false, timeout: TimeInterval = 10) {
        self.client = client; self.queue = queue; self.router = router; preserveOriginal = preserveOriginalInterface; self.timeout = timeout
    }
    public func start() {
        guard !started, !closed else { return }; started = true
        guard timeout.isFinite, (0.01...60).contains(timeout) else { finish(.invalidConfiguration); return }
        let source = DispatchSource.makeTimerSource(queue: queue); timer = source
        source.setEventHandler { [weak self] in self?.finish(.timedOut) }; source.schedule(deadline: .now() + timeout); source.resume()
        read()
    }
    private func read() {
        client.receive { [weak self] bytes, eof, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.finish(.connectionFailed); return }
            self.eof = eof
            do { try self.framer.append(bytes ?? Data()); self.process() } catch { self.finish(.capacity) }
        }
    }
    private func process() {
        guard !closed else { return }
        do {
            guard let message = try framer.next() else {
                if eof { finish(framer.isEmpty ? nil : .invalidRequest) } else { read() }; return
            }
            guard let parsed = try? DNSPacket(message, response: false) else { finish(.invalidRequest); return }
            timer?.schedule(deadline: .now() + timeout)
            ticket = router.exchange(message, preserveOriginalInterface: preserveOriginal, udp: false) { [weak self] result in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, !self.closed else { return }; self.ticket = nil
                    let response = (try? result.get()) ?? parsed.failureReply()
                    guard let frame = try? DNSStreamFramer.frame(response) else { self.finish(.invalidRequest); return }
                    self.client.send(frame, final: false) { [weak self] error in
                        guard let self, !self.closed else { return }
                        if error != nil { self.finish(.connectionFailed) }
                        else { self.timer?.schedule(deadline: .now() + self.timeout); self.process() }
                    }
                }
            }
        } catch { finish(.invalidRequest) }
    }
    public func stop() { finish(nil) }
    private func finish(_ error: CoreError?) {
        guard !closed else { return }; closed = true
        ticket?.cancel(); ticket = nil; timer?.cancel(); timer = nil; client.cancel()
        let callback = onFinish; onFinish = nil; callback?(error)
    }
    deinit { ticket?.cancel(); timer?.cancel(); if !closed { client.cancel() } }
}

/// DNS-over-UDP source endpoints remain the original resolver endpoints when responses return.
/// One query is exchanged at a time; encrypted errors return SERVFAIL, never plaintext fallback.
public final class DNSDatagramSession {
    private let flow: DatagramFlow
    private let queue: DispatchQueue
    private let makeRouter: (DatagramEndpoint) -> DNSQueryRouter
    private let preserveOriginal: Bool
    private let timeout: TimeInterval
    private var batch = [Datagram]()
    private var index = 0
    private var ticket: ResolutionTicket?
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var started = false
    public var onFinish: ((CoreError?) -> Void)?
    public init(flow: DatagramFlow, queue: DispatchQueue, preserveOriginalInterface: Bool = false, timeout: TimeInterval = 10,
                makeRouter: @escaping (DatagramEndpoint) -> DNSQueryRouter) {
        self.flow = flow; self.queue = queue; self.makeRouter = makeRouter; preserveOriginal = preserveOriginalInterface; self.timeout = timeout
    }
    public func start() {
        guard !closed, !started else { return }; started = true
        guard timeout.isFinite, (0.01...60).contains(timeout) else { finish(.invalidConfiguration); return }
        let source = DispatchSource.makeTimerSource(queue: queue); timer = source
        source.setEventHandler { [weak self] in self?.finish(.timedOut) }; source.schedule(deadline: .now() + timeout); source.resume()
        read()
    }
    private func read() {
        flow.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error): self.finish(error)
            case .success(let batch):
                if batch.isEmpty { self.finish(nil); return }
                guard batch.count <= 32, batch.reduce(0, { $0 + $1.data.count }) <= 262_144 else { self.finish(.capacity); return }
                self.batch = batch; self.index = 0; self.process()
            }
        }
    }
    private func process() {
        guard !closed else { return }
        guard index < batch.count else { batch.removeAll(); read(); return }
        let request = batch[index]
        guard request.endpoint.port == 53, let query = try? DNSPacket(request.data, response: false) else { finish(.invalidRequest); return }
        timer?.schedule(deadline: .now() + timeout)
        ticket = makeRouter(request.endpoint).exchange(request.data, preserveOriginalInterface: preserveOriginal, udp: true) { [weak self] result in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.closed else { return }; self.ticket = nil
                let bytes = (try? result.get()) ?? query.failureReply()
                self.flow.send(Datagram(data: bytes, endpoint: request.endpoint)) { [weak self] error in
                    guard let self, !self.closed else { return }
                    if error != nil { self.finish(.connectionFailed) }
                    else { self.index += 1; self.timer?.schedule(deadline: .now() + self.timeout); self.process() }
                }
            }
        }
    }
    public func stop() { finish(nil) }
    private func finish(_ error: CoreError?) {
        guard !closed else { return }; closed = true
        ticket?.cancel(); ticket = nil; timer?.cancel(); timer = nil; batch.removeAll(); flow.cancel()
        let callback = onFinish; onFinish = nil; callback?(error)
    }
    deinit { ticket?.cancel(); timer?.cancel(); if !closed { flow.cancel() } }
}
