import Foundation
import Network
import Darwin

public enum DestinationPolicy {
    public static func permits(_ address: String, allowLoopback: Bool = false) -> Bool {
        if let ip = IPv4Address(address) {
            let b = [UInt8](ip.rawValue)
            if b[0] == 127 { return allowLoopback }
            return b[0] != 0 && b[0] != 10 && b[0] < 224 &&
                !(b[0] == 100 && (64...127).contains(b[1])) &&
                !(b[0] == 169 && b[1] == 254) && !(b[0] == 172 && (16...31).contains(b[1])) &&
                !(b[0] == 192 && (b[1] == 0 || b[1] == 168 || (b[1] == 2))) &&
                !(b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) &&
                !(b[0] == 203 && b[1] == 0 && b[2] == 113)
        }
        if let ip = IPv6Address(address) {
            let b = [UInt8](ip.rawValue)
            if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return allowLoopback }
            // Only global unicast; reject mapped IPv4, NAT64, ULA, multicast, link local and documentation.
            return b[0] & 0xe0 == 0x20 && !(b[0] == 0x20 && b[1] == 1 && b[2] == 0x0d && b[3] == 0xb8)
                && !(b[0] == 0x20 && b[1] == 1 && b[2] == 0 && b[3] == 0)
        }
        return false
    }
}

/// Cancellation is synchronous and thread-safe. An OS lookup already in progress may finish,
/// but queued work and delivery to a cancelled session are suppressed.
public final class ResolutionTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellation: (() -> Void)?
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let action = cancellation; cancellation = nil; lock.unlock()
        action?()
    }
    public func onCancel(_ action: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); action() }
        else { cancellation = action; lock.unlock() }
    }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public protocol HostResolving: AnyObject {
    @discardableResult
    func resolve(_ host: String, completion: @escaping (Result<[String], CoreError>) -> Void) -> ResolutionTicket
    func shutdown()
}

public extension HostResolving { func shutdown() {} }

/// One bounded worker, no detached task per request. The injected lookup supports controlled failure tests.
public final class SystemResolver: HostResolving, @unchecked Sendable {
    private let worker = DispatchQueue(label: "io.macdpi.dns", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private let lookup: (String) -> Result<[String], CoreError>
    public init(lookup: @escaping (String) -> Result<[String], CoreError> = SystemResolver.systemLookup) { self.lookup = lookup }

    @discardableResult
    public func resolve(_ host: String, completion: @escaping (Result<[String], CoreError>) -> Void) -> ResolutionTicket {
        let ticket = ResolutionTicket()
        if IPv4Address(host) != nil || IPv6Address(host) != nil { completion(.success([host])); return ticket }
        lock.lock()
        guard pending < 64 else { lock.unlock(); completion(.failure(.capacity)); return ticket }
        pending += 1
        lock.unlock()
        worker.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            guard !ticket.isCancelled else { return }
            let result = self.lookup(host)
            guard !ticket.isCancelled else { return }
            completion(result)
        }
        return ticket
    }

    public static func systemLookup(_ host: String) -> Result<[String], CoreError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return .failure(.resolutionFailed) }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        var addresses = [String]()
        while let item = current, addresses.count < 16 {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: name)
                if !addresses.contains(address) { addresses.append(address) }
            }
            current = item.pointee.ai_next
        }
        return addresses.isEmpty ? .failure(.resolutionFailed) : .success(addresses)
    }
}
