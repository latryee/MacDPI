import Foundation
import Network

/// A small DNS wire-format codec. No packet capture, DNS settings, or trust overrides.
enum DNSMessage {
    struct Answer { let addresses: [String]; let ttl: UInt32 }
    static let maximumSize = 32_768

    static func query(host: String, type: UInt16) throws -> Data {
        guard type == 1 || type == 28, !host.isEmpty, host.utf8.count <= 253 else { throw CoreError.resolutionFailed }
        var out = Data([0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in host.lowercased().split(separator: ".", omittingEmptySubsequences: false) {
            let b = Array(label.utf8)
            guard (1...63).contains(b.count), b.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  b.first != 45, b.last != 45 else { throw CoreError.resolutionFailed }
            out.append(UInt8(b.count)); out.append(contentsOf: b)
        }
        out.append(contentsOf: [0, UInt8(type >> 8), UInt8(type & 255), 0, 1])
        return out
    }

    static func parse(_ data: Data, host: String, type: UInt16) throws -> Answer {
        guard (12...maximumSize).contains(data.count) else { throw CoreError.resolutionFailed }
        let b = [UInt8](data)
        func u16(_ p: Int) throws -> Int {
            guard p >= 0, p + 2 <= b.count else { throw CoreError.resolutionFailed }
            return Int(b[p]) << 8 | Int(b[p+1])
        }
        func name(_ cursor: inout Int) throws -> String {
            var p = cursor, end: Int?, labels = [String](), visited = Set<Int>(), size = 0
            while true {
                guard p < b.count, visited.insert(p).inserted, visited.count <= 128 else { throw CoreError.resolutionFailed }
                let n = Int(b[p])
                if n & 0xc0 == 0xc0 {
                    let target = try u16(p) & 0x3fff
                    // Compression pointers must point backwards and outside the fixed header.
                    guard target >= 12, target < p else { throw CoreError.resolutionFailed }
                    if end == nil { end = p + 2 }; p = target; continue
                }
                guard n <= 63, p + 1 + n <= b.count else { throw CoreError.resolutionFailed }
                p += 1
                if n == 0 { cursor = end ?? p; return labels.joined(separator: ".").lowercased() }
                size += n + 1
                guard size <= 254, let label = String(bytes: b[p..<(p+n)], encoding: .ascii),
                      !label.contains("."), !label.contains("\0") else { throw CoreError.resolutionFailed }
                labels.append(label); p += n
            }
        }
        let flags = try u16(2)
        guard try u16(0) == 0, flags & 0x8000 != 0, flags & 0x780f == 0,
              flags & 0x0200 == 0, try u16(4) == 1 else { throw CoreError.resolutionFailed }
        let answerCount = try u16(6), authorityCount = try u16(8), additionalCount = try u16(10)
        guard answerCount + authorityCount + additionalCount <= 256 else { throw CoreError.resolutionFailed }
        var p = 12
        guard try name(&p) == host.lowercased(), try u16(p) == Int(type), try u16(p+2) == 1 else { throw CoreError.resolutionFailed }
        p += 4
        var aliases = [String: String](), records = [(String, String, UInt32)](), ttl: UInt32 = 300
        for i in 0..<(answerCount + authorityCount + additionalCount) {
            let owner = try name(&p), kind = try u16(p), cls = try u16(p+2)
            guard p + 10 <= b.count else { throw CoreError.resolutionFailed }
            let recordTTL = UInt32(b[p+4]) << 24 | UInt32(b[p+5]) << 16 | UInt32(b[p+6]) << 8 | UInt32(b[p+7])
            let length = try u16(p+8); p += 10
            guard length <= b.count - p else { throw CoreError.resolutionFailed }
            let end = p + length
            if i < answerCount && cls == 1 {
                if kind == 5 {
                    var q = p; let target = try name(&q)
                    guard q == end, aliases[owner] == nil else { throw CoreError.resolutionFailed }
                    aliases[owner] = target; ttl = min(ttl, recordTTL)
                } else if kind == Int(type) {
                    let raw = Data(b[p..<end])
                    let address = kind == 1 && length == 4 ? IPv4Address(raw)?.debugDescription
                        : kind == 28 && length == 16 ? IPv6Address(raw)?.debugDescription : nil
                    guard let address else { throw CoreError.resolutionFailed }
                    records.append((owner, address, recordTTL))
                }
            }
            p = end
        }
        guard p == b.count else { throw CoreError.resolutionFailed }
        var owner = host.lowercased(), seen = Set<String>()
        while let alias = aliases[owner] {
            guard seen.insert(owner).inserted, seen.count <= 16 else { throw CoreError.resolutionFailed }
            owner = alias
        }
        var addresses = [String]()
        for record in records where record.0 == owner {
            // Rechecked by ProxySession before every numeric connection, including cache hits.
            guard DestinationPolicy.permits(record.1) else { throw CoreError.forbiddenDestination }
            if !addresses.contains(record.1), addresses.count < 16 { addresses.append(record.1) }
            ttl = min(ttl, record.2)
        }
        return Answer(addresses: addresses, ttl: ttl)
    }
}

/// URLSession keeps certificate validation enabled. The numeric HTTPS endpoint avoids a poisoned
/// bootstrap lookup; its certificate must cover 1.1.1.1. No cookies, disk cache, redirects, or fallback.
final class DNSHTTPTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Completion = (Result<Data, CoreError>) -> Void
    private struct Job { var data = Data(); let completion: Completion }
    private let lock = NSLock()
    private var jobs = [Int: Job]()
    private var stopped = false
    private var session: URLSession!

    init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        let config = configuration
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:] // Explicit direct bootstrap, never through our own listener.
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 6
        config.httpMaximumConnectionsPerHost = 4
        let callbacks = OperationQueue(); callbacks.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: callbacks)
    }
    func request(_ message: Data, completion: @escaping Completion) -> ResolutionTicket {
        let ticket = ResolutionTicket()
        var request = URLRequest(url: URL(string: "https://1.1.1.1/dns-query")!)
        request.httpMethod = "POST"; request.httpBody = message
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        lock.lock()
        guard !stopped, jobs.count < 128 else { lock.unlock(); completion(.failure(.capacity)); return ticket }
        let task = session.dataTask(with: request)
        jobs[task.taskIdentifier] = Job(completion: completion)
        lock.unlock()
        ticket.onCancel { task.cancel() }; task.resume()
        return ticket
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let valid = http?.statusCode == 200 && http?.mimeType?.lowercased() == "application/dns-message"
            && response.expectedContentLength <= DNSMessage.maximumSize
        completionHandler(valid ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var job = jobs[dataTask.taskIdentifier] else { lock.unlock(); return }
        guard data.count <= DNSMessage.maximumSize - job.data.count else { lock.unlock(); dataTask.cancel(); return }
        job.data.append(data); jobs[dataTask.taskIdentifier] = job; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let job = jobs.removeValue(forKey: task.taskIdentifier); lock.unlock()
        if let job { job.completion(error == nil ? .success(job.data) : .failure(.resolutionFailed)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func shutdown() {
        lock.lock(); stopped = true; jobs.removeAll(); lock.unlock()
        session.invalidateAndCancel()
    }
}

/// Per-engine bounded, coalesced A/AAAA queries and a small TTL-limited RAM cache, erased on stop.
public final class HTTPSResolver: HostResolving, @unchecked Sendable {
    typealias Request = (Data, @escaping DNSHTTPTransport.Completion) -> ResolutionTicket
    private struct Waiter { let ticket: ResolutionTicket; let completion: (Result<[String], CoreError>) -> Void }
    private struct Pending {
        let generation = UUID()
        var waiters = [UUID: Waiter](); var tickets = [ResolutionTicket]()
        var answers = [UInt16: DNSMessage.Answer](); var remaining = 2
    }
    private let queue = DispatchQueue(label: "io.macdpi.https-dns", qos: .utility)
    private let request: Request
    private let closeTransport: () -> Void
    private var pending = [String: Pending]()
    private var cache = [String: (addresses: [String], expires: Date)]()
    private var stopped = false
    public init() {
        let transport = DNSHTTPTransport()
        request = transport.request; closeTransport = transport.shutdown
    }
    init(request: @escaping Request, close: @escaping () -> Void = {}) { self.request = request; closeTransport = close }

    @discardableResult
    public func resolve(_ host: String, completion: @escaping (Result<[String], CoreError>) -> Void) -> ResolutionTicket {
        let ticket = ResolutionTicket(), id = UUID(), host = host.lowercased()
        ticket.onCancel { [weak self] in self?.queue.async { [weak self] in self?.cancel(host: host, id: id) } }
        queue.async { [self] in
            guard !ticket.isCancelled else { return }
            guard !stopped else { completion(.failure(.stopped)); return }
            if IPv4Address(host) != nil || IPv6Address(host) != nil { completion(.success([host])); return }
            guard (try? DNSMessage.query(host: host, type: 1)) != nil else { completion(.failure(.resolutionFailed)); return }
            if let hit = cache[host], hit.expires > Date() { completion(.success(hit.addresses)); return }
            cache.removeValue(forKey: host)
            guard pending.values.reduce(0, { $0 + $1.waiters.count }) < 64 else { completion(.failure(.capacity)); return }
            let waiter = Waiter(ticket: ticket, completion: completion)
            if pending[host] != nil { pending[host]?.waiters[id] = waiter; return }
            pending[host] = Pending(waiters: [id: waiter])
            let generation = pending[host]!.generation
            for type: UInt16 in [1, 28] {
                let task = request(try! DNSMessage.query(host: host, type: type)) { [weak self] result in
                    self?.queue.async { [weak self] in self?.received(result, host: host, type: type, generation: generation) }
                }
                pending[host]?.tickets.append(task)
            }
        }
        return ticket
    }
    private func received(_ result: Result<Data, CoreError>, host: String, type: UInt16, generation: UUID) {
        guard var item = pending[host], item.generation == generation else { return }
        if case .success(let data) = result, let answer = try? DNSMessage.parse(data, host: host, type: type) { item.answers[type] = answer }
        item.remaining -= 1
        guard item.remaining == 0 else { pending[host] = item; return }
        pending.removeValue(forKey: host)
        let answers = [UInt16(1), 28].compactMap { item.answers[$0] }
        let addresses = Array(answers.flatMap(\.addresses).prefix(16))
        let ttl = answers.map(\.ttl).min() ?? 0
        if !addresses.isEmpty && ttl > 0 {
            cache = cache.filter { $0.value.expires > Date() }
            if cache.count >= 256, let key = cache.min(by: { $0.value.expires < $1.value.expires })?.key { cache.removeValue(forKey: key) }
            cache[host] = (addresses, Date().addingTimeInterval(Double(min(300, ttl))))
        }
        for waiter in item.waiters.values where !waiter.ticket.isCancelled {
            waiter.completion(addresses.isEmpty ? .failure(.resolutionFailed) : .success(addresses))
        }
    }
    private func cancel(host: String, id: UUID) {
        guard var item = pending[host] else { return }
        item.waiters.removeValue(forKey: id)
        if item.waiters.isEmpty { pending.removeValue(forKey: host); item.tickets.forEach { $0.cancel() } }
        else { pending[host] = item }
    }
    public func shutdown() {
        queue.async { [self] in
            stopped = true; cache.removeAll()
            for item in pending.values { item.tickets.forEach { $0.cancel() } }
            pending.removeAll(); closeTransport()
        }
    }
    deinit { closeTransport() }
}
