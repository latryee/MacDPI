import Foundation
import Network
import Darwin

/// A public BSD connected UDP socket, driven by dispatch readiness events. A zero-length
/// recvmsg result is a datagram, never stream EOF. There is one outstanding read and send,
/// no user-space send queue, no listener, and no DNS lookup. All calls after start must use
/// the supplied serial queue. This transport does not attach another application's identity
/// to its socket; the provider must exclude its own outbound traffic to prevent recursion.
public final class UDPTransport: DatagramTransport {
    // Dispatch sources must finish cancellation before their descriptor can be reused.
    private final class Descriptor {
        let value: Int32
        private let lock = NSLock()
        private var sources = 2
        init(_ value: Int32) { self.value = value }
        func sourceCancelled() {
            lock.lock(); sources -= 1; let closeNow = sources == 0; lock.unlock()
            if closeNow { Darwin.close(value) }
        }
    }
    private struct PendingSend { let data: Data; let completion: (Error?) -> Void }
    private let endpoint: DatagramEndpoint
    private let interfaceIndex: UInt32?
    private var queue: DispatchQueue?
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readSuspended = true
    private var writeSuspended = true
    private var pendingRead: ((Data?, Bool, Error?) -> Void)?
    private var pendingSend: PendingSend?
    private var started = false
    private var cancelled = false

    /// interfaceIndex pins the socket using IP_BOUND_IF/IPV6_BOUND_IF without changing routes.
    public init(endpoint: DatagramEndpoint, interfaceIndex: UInt32? = nil) {
        self.endpoint = endpoint; self.interfaceIndex = interfaceIndex
    }

    public func start(queue: DispatchQueue, completion: @escaping (Result<Void, CoreError>) -> Void) {
        guard !started, !cancelled else { completion(.failure(.stopped)); return }
        started = true; self.queue = queue
        guard let numeric = endpoint.canonicalNumeric else { completion(.failure(.forbiddenDestination)); return }
        let ipv4 = IPv4Address(numeric.host)
        let family = ipv4 == nil ? AF_INET6 : AF_INET
        let fd = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { completion(.failure(.connectionFailed)); return }
        var keep = false
        defer { if !keep { Darwin.close(fd) } }
        let flags = fcntl(fd, F_GETFL, 0), descriptorFlags = fcntl(fd, F_GETFD, 0)
        guard flags >= 0, descriptorFlags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            completion(.failure(.connectionFailed)); return
        }
        // Permit the configured ordinary maximum datagram size while keeping kernel queues bounded.
        var bufferBytes: Int32 = 262_144
        guard setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferBytes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferBytes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            completion(.failure(.connectionFailed)); return
        }
        if var index = interfaceIndex {
            guard index != 0,
                  setsockopt(fd, ipv4 == nil ? IPPROTO_IPV6 : IPPROTO_IP,
                             ipv4 == nil ? IPV6_BOUND_IF : IP_BOUND_IF, &index,
                             socklen_t(MemoryLayout.size(ofValue: index))) == 0 else {
                completion(.failure(.connectionFailed)); return
            }
        }
        let connected: Int32
        if let ipv4 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = numeric.port.bigEndian
            _ = withUnsafeMutableBytes(of: &address.sin_addr) { ipv4.rawValue.copyBytes(to: $0) }
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = numeric.port.bigEndian
            let ipv6 = IPv6Address(numeric.host)!
            _ = withUnsafeMutableBytes(of: &address.sin6_addr) { ipv6.rawValue.copyBytes(to: $0) }
            connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard connected == 0 else { completion(.failure(.connectionFailed)); return }
        descriptor = fd
        let lifetime = Descriptor(fd)
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.receiveReady() }
        write.setEventHandler { [weak self] in self?.sendReady() }
        read.setCancelHandler { lifetime.sourceCancelled() }
        write.setCancelHandler { lifetime.sourceCancelled() }
        readSource = read; writeSource = write
        keep = true
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            completion(.success(()))
        }
    }

    public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard !cancelled, descriptor >= 0 else { completion(Self.error(ECANCELED)); return }
        guard pendingSend == nil else { completion(Self.error(EBUSY)); return }
        guard data.count <= 65_507 else { completion(Self.error(EMSGSIZE)); return }
        pendingSend = PendingSend(data: data, completion: completion)
        sendReady()
    }

    private func sendReady() {
        guard !cancelled, let pending = pendingSend else { return }
        let count = pending.data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            if writeSuspended { writeSuspended = false; writeSource?.resume() }
            return
        }
        let error: Error? = count < 0 ? Self.error(errno) : (count == pending.data.count ? nil : Self.error(EIO))
        pendingSend = nil
        if !writeSuspended { writeSuspended = true; writeSource?.suspend() }
        queue?.async { [weak self] in
            guard let self, !self.cancelled else { return }
            pending.completion(error)
        }
    }

    public func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void) {
        guard !cancelled, descriptor >= 0 else { completion(nil, false, Self.error(ECANCELED)); return }
        guard pendingRead == nil else { completion(nil, false, Self.error(EBUSY)); return }
        pendingRead = completion
        receiveReady()
    }

    private func receiveReady() {
        guard !cancelled, let completion = pendingRead else { return }
        // recvmsg initializes the received prefix. Avoid zeroing or retaining a maximum-size
        // buffer for each attempt, including a would-block result or an empty datagram.
        let (data, complete, failure) = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 65_536) { buffer -> (Data?, Bool, Int32) in
            guard let base = buffer.baseAddress else { return (nil, false, ENOMEM) }
            var vector = iovec(iov_base: base, iov_len: buffer.count)
            var message = msghdr()
            let count = withUnsafeMutablePointer(to: &vector) { pointer in
                message.msg_iov = pointer; message.msg_iovlen = 1
                return Darwin.recvmsg(descriptor, &message, 0)
            }
            guard count >= 0 else { return (nil, false, errno) }
            return (Data(bytes: base, count: count), message.msg_flags & MSG_TRUNC == 0, 0)
        }
        if failure == EAGAIN || failure == EWOULDBLOCK || failure == EINTR {
            if readSuspended { readSuspended = false; readSource?.resume() }
            return
        }
        let error: Error? = failure == 0 ? nil : Self.error(failure)
        pendingRead = nil
        if !readSuspended { readSuspended = true; readSource?.suspend() }
        queue?.async { [weak self] in
            guard let self, !self.cancelled else { return }
            completion(data, complete, error)
        }
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true; pendingRead = nil; pendingSend = nil; descriptor = -1
        readSource?.setEventHandler {}; writeSource?.setEventHandler {}
        readSource?.cancel(); writeSource?.cancel()
        if readSuspended { readSource?.resume() }
        if writeSuspended { writeSource?.resume() }
        readSource = nil; writeSource = nil
    }
    private static func error(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    deinit { cancel() }
}
