import XCTest
import Network
import Darwin
@testable import MacDPICore

private final class TestDatagramFlow: DatagramFlow {
    var pendingRead: ((Result<[Datagram], CoreError>) -> Void)?
    var sent = [Datagram]()
    var receiveCount = 0
    var cancelCount = 0
    var deferWrites = false
    var writes = [(Error?) -> Void]()
    var onSend: ((Datagram) -> Void)?
    func receive(_ completion: @escaping (Result<[Datagram], CoreError>) -> Void) {
        XCTAssertNil(pendingRead, "Concurrent source reads")
        receiveCount += 1; pendingRead = completion
    }
    func send(_ datagram: Datagram, completion: @escaping (Error?) -> Void) {
        sent.append(datagram); onSend?(datagram)
        if deferWrites { writes.append(completion) } else { completion(nil) }
    }
    func cancel() { cancelCount += 1 }
    func emit(_ datagrams: [Datagram]) {
        let callback = pendingRead; pendingRead = nil
        XCTAssertNotNil(callback); callback?(.success(datagrams))
    }
}

private final class TestDatagramTransport: DatagramTransport {
    var pendingRead: ((Data?, Bool, Error?) -> Void)?
    var pendingStart: ((Result<Void, CoreError>) -> Void)?
    var deferStart = false
    var deferSends = false
    var sent = [Data]()
    var sends = [(Error?) -> Void]()
    var receiveCount = 0
    var cancelCount = 0
    func start(queue: DispatchQueue, completion: @escaping (Result<Void, CoreError>) -> Void) {
        if deferStart { pendingStart = completion } else { completion(.success(())) }
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        sent.append(data)
        if deferSends { sends.append(completion) } else { completion(nil) }
    }
    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void) {
        XCTAssertNil(pendingRead, "Concurrent endpoint reads")
        receiveCount += 1; pendingRead = completion
    }
    func cancel() { cancelCount += 1 }
    func emit(_ data: Data?, complete: Bool = true, error: Error? = nil) {
        let callback = pendingRead; pendingRead = nil
        XCTAssertNotNil(callback); callback?(data, complete, error)
    }
}

/// An independent loopback fixture verifies on-wire UDP behavior, including empty datagrams.
/// It deliberately does not use NWConnection's message/end-of-context representation.
private final class NativeUDPEchoFixture {
    let port: UInt16
    private let descriptor: Int32
    private var source: DispatchSourceRead?
    private(set) var received = [Data]()

    init(ipv6: Bool, queue: DispatchQueue) throws {
        let fd = Darwin.socket(ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var keep = false
        defer { if !keep { Darwin.close(fd) } }
        var bufferBytes: Int32 = 262_144
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferBytes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferBytes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard withUnsafeMutablePointer(to: &address, { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }) == 0 else { throw POSIXError(.EIO) }
            port = UInt16(bigEndian: address.sin6_port)
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard withUnsafeMutablePointer(to: &address, { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }) == 0 else { throw POSIXError(.EIO) }
            port = UInt16(bigEndian: address.sin_port)
        }
        descriptor = fd
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source = read
        read.setEventHandler { [weak self] in self?.echoReady() }
        read.setCancelHandler { Darwin.close(fd) }
        keep = true; read.resume()
    }

    private func echoReady() {
        // Bound each event's work so cancellation and timers can run even during a burst.
        for _ in 0..<32 {
            var bytes = [UInt8](repeating: 0, count: 65_536), sender = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = bytes.withUnsafeMutableBytes { buffer in
                withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, buffer.baseAddress, buffer.count, 0, $0, &length)
                    }
                }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { XCTFail("UDP fixture receive failed: \(errno)") }
                return
            }
            received.append(Data(bytes.prefix(count)))
            let sent = bytes.withUnsafeBytes { buffer in
                withUnsafePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, buffer.baseAddress, count, 0, $0, length)
                    }
                }
            }
            XCTAssertEqual(sent, count, "UDP fixture echo failed: \(errno)")
        }
    }
    func cancel() { source?.setEventHandler {}; source?.cancel(); source = nil }
    deinit { cancel() }
}

final class UDPTests: XCTestCase {
    private let first = DatagramEndpoint(host: "1.1.1.1", port: 443)
    private let second = DatagramEndpoint(host: "2606:4700:4700::1111", port: 3478)

    func testNumericEndpointValidationAndExplicitExclusions() throws {
        XCTAssertEqual(try first.validated(), first)
        XCTAssertEqual(try DatagramEndpoint(host: "2606:4700:4700:0:0:0:0:1111", port: 443).validated().host, "2606:4700:4700::1111")
        for host in ["localhost", "example.com", "127.0.0.1", "::1", "10.0.0.1", "192.168.0.1", "169.254.0.1", "224.0.0.1", "::ffff:1.1.1.1", "64:ff9b::101:101", "2001:db8::1", "fe80::1", "2606:4700::1111%en0"] {
            XCTAssertThrowsError(try DatagramEndpoint(host: host, port: 443).validated(), host)
        }
        XCTAssertThrowsError(try DatagramEndpoint(host: "1.1.1.1", port: 0).validated())
        XCTAssertEqual(try DatagramEndpoint(host: "::1", port: 12345).validated(allowLoopback: true).host, "::1")
        var config = DatagramConfiguration(); config.maximumEndpoints = 65
        XCTAssertThrowsError(try config.validated())
        config = DatagramConfiguration(); config.idleTimeout = .nan
        XCTAssertThrowsError(try config.validated())
        config = DatagramConfiguration(); config.excludedEndpoints = [DatagramEndpoint(host: "unresolved.test", port: 123)]
        XCTAssertThrowsError(try config.validated())
    }

    func testBoundariesZeroLengthFanoutAndReplySourcePreservation() {
        let queue = DispatchQueue(label: "test.udp.boundaries"), flow = TestDatagramFlow()
        var transports = [DatagramEndpoint: TestDatagramTransport]()
        let session = DatagramSession(flow: flow, queue: queue) { endpoint in
            let transport = TestDatagramTransport(); transports[endpoint] = transport; return transport
        }
        queue.sync {
            session.start()
            let packets = [Datagram(data: Data(), endpoint: first), Datagram(data: Data([1, 2]), endpoint: first),
                           Datagram(data: Data([3]), endpoint: second)]
            flow.emit(packets)
            XCTAssertEqual(transports.count, 2)
            XCTAssertEqual(transports[first]?.sent, [Data(), Data([1, 2])])
            XCTAssertEqual(transports[second]?.sent, [Data([3])])
            XCTAssertEqual(flow.receiveCount, 2)
            transports[first]?.emit(Data())
            transports[second]?.emit(Data([4, 5, 6]))
            XCTAssertEqual(flow.sent.map(\.data), [Data(), Data([4, 5, 6])])
            XCTAssertEqual(flow.sent.map(\.endpoint), [first, second])
            session.stop()
        }
    }

    func testSourceAndReplyBackpressure() {
        let queue = DispatchQueue(label: "test.udp.backpressure"), flow = TestDatagramFlow()
        let transport = TestDatagramTransport(); transport.deferSends = true; flow.deferWrites = true
        let session = DatagramSession(flow: flow, queue: queue, makeTransport: { _ in transport })
        queue.sync {
            session.start(); flow.emit([Datagram(data: Data([1]), endpoint: first), Datagram(data: Data([2]), endpoint: first)])
            XCTAssertEqual(transport.sent.count, 1); XCTAssertEqual(flow.receiveCount, 1)
            transport.sends.removeFirst()(nil)
            XCTAssertEqual(transport.sent.count, 2); XCTAssertEqual(flow.receiveCount, 1)
            transport.sends.removeFirst()(nil)
            XCTAssertEqual(flow.receiveCount, 2)
            transport.emit(Data([9]))
            XCTAssertEqual(flow.sent.count, 1); XCTAssertNil(transport.pendingRead)
            flow.writes.removeFirst()(nil)
            XCTAssertNotNil(transport.pendingRead)
            session.stop()
        }
    }

    func testInvalidBatchRejectedBeforeSendingAndLocalDNSNotRelayed() {
        let cases = [DatagramEndpoint(host: "192.168.1.2", port: 5000), DatagramEndpoint(host: "example.com", port: 5000),
                     DatagramEndpoint(host: "1.1.1.1", port: 53)]
        for forbidden in cases {
            let queue = DispatchQueue(label: "test.udp.reject"), flow = TestDatagramFlow()
            var created = 0, result: CoreError?
            let session = DatagramSession(flow: flow, queue: queue) { _ in created += 1; return TestDatagramTransport() }
            queue.sync {
                session.onFinish = { result = $0 }; session.start()
                flow.emit([Datagram(data: Data([1]), endpoint: first), Datagram(data: Data([2]), endpoint: forbidden)])
                XCTAssertEqual(result, .forbiddenDestination); XCTAssertEqual(created, 0)
                XCTAssertEqual(flow.cancelCount, 1)
            }
        }
        let queue = DispatchQueue(label: "test.udp.loop"), flow = TestDatagramFlow()
        var config = DatagramConfiguration(); config.excludedEndpoints = [second]
        var created = 0, result: CoreError?
        let session = DatagramSession(flow: flow, queue: queue, configuration: config) { _ in created += 1; return TestDatagramTransport() }
        queue.sync {
            session.onFinish = { result = $0 }; session.start()
            flow.emit([Datagram(data: Data(), endpoint: second)])
            XCTAssertEqual(result, .forbiddenDestination); XCTAssertEqual(created, 0)
        }
    }

    func testEndpointBatchAndPayloadBounds() {
        for mode in 0..<4 {
            let queue = DispatchQueue(label: "test.udp.bounds"), flow = TestDatagramFlow()
            var config = DatagramConfiguration(); config.maximumEndpoints = 1
            config.maximumDatagramSize = 8; config.maximumBatchBytes = 8; config.maximumBatchCount = 2
            var created = 0, result: CoreError?
            let session = DatagramSession(flow: flow, queue: queue, configuration: config) { _ in created += 1; return TestDatagramTransport() }
            let packets: [Datagram]
            switch mode {
            case 0: packets = [Datagram(data: Data([1]), endpoint: first), Datagram(data: Data([2]), endpoint: second)]
            case 1: packets = [Datagram(data: Data(repeating: 1, count: 9), endpoint: first)]
            case 2: packets = [Datagram(data: Data(repeating: 1, count: 5), endpoint: first), Datagram(data: Data(repeating: 2, count: 5), endpoint: first)]
            default: packets = [Datagram](repeating: Datagram(data: Data(), endpoint: first), count: 3)
            }
            queue.sync {
                session.onFinish = { result = $0 }; session.start(); flow.emit(packets)
                XCTAssertEqual(result, .capacity); XCTAssertEqual(created, 0)
            }
        }
    }

    func testReplySizeIncompletePacketAndQueueBounds() {
        for mode in 0..<3 {
            let queue = DispatchQueue(label: "test.udp.reply-bounds"), flow = TestDatagramFlow()
            flow.deferWrites = true
            var config = DatagramConfiguration(); config.maximumDatagramSize = 8; config.maximumReplyBytes = 8
            var transports = [DatagramEndpoint: TestDatagramTransport](), result: CoreError?
            let session = DatagramSession(flow: flow, queue: queue, configuration: config) { endpoint in
                let transport = TestDatagramTransport(); transports[endpoint] = transport; return transport
            }
            queue.sync {
                session.onFinish = { result = $0 }; session.start()
                flow.emit([Datagram(data: Data(), endpoint: first), Datagram(data: Data(), endpoint: second)])
                if mode == 0 { transports[first]?.emit(Data(repeating: 1, count: 9)) }
                else if mode == 1 { transports[first]?.emit(Data([1]), complete: false) }
                else {
                    transports[first]?.emit(Data(repeating: 1, count: 5))
                    transports[second]?.emit(Data(repeating: 2, count: 5))
                }
                XCTAssertEqual(result, .capacity)
                XCTAssertTrue(transports.values.allSatisfy { $0.cancelCount == 1 })
            }
        }
    }

    func testZeroLengthRepliesStillConsumeReplyCountCapacity() {
        let queue = DispatchQueue(label: "test.udp.empty-reply-limit"), flow = TestDatagramFlow()
        flow.deferWrites = true
        var config = DatagramConfiguration(); config.maximumReplyCount = 1
        var transports = [DatagramEndpoint: TestDatagramTransport](), result: CoreError?
        let session = DatagramSession(flow: flow, queue: queue, configuration: config) { endpoint in
            let transport = TestDatagramTransport(); transports[endpoint] = transport; return transport
        }
        queue.sync {
            session.onFinish = { result = $0 }; session.start()
            flow.emit([Datagram(data: Data(), endpoint: first), Datagram(data: Data(), endpoint: second)])
            transports[first]?.emit(Data())
            XCTAssertNil(result); XCTAssertEqual(flow.sent.count, 1)
            transports[second]?.emit(Data())
            XCTAssertEqual(result, .capacity); XCTAssertEqual(flow.cancelCount, 1)
            XCTAssertTrue(transports.values.allSatisfy { $0.cancelCount == 1 })
        }
    }

    func testFanoutLimitAccumulatesAcrossSourceBatches() {
        let queue = DispatchQueue(label: "test.udp.accumulated-fanout"), flow = TestDatagramFlow()
        var config = DatagramConfiguration(); config.maximumEndpoints = 1
        var created = 0, result: CoreError?
        let session = DatagramSession(flow: flow, queue: queue, configuration: config) { _ in
            created += 1; return TestDatagramTransport()
        }
        queue.sync {
            session.onFinish = { result = $0 }; session.start()
            flow.emit([Datagram(data: Data(), endpoint: first)])
            XCTAssertNil(result); XCTAssertEqual(created, 1)
            flow.emit([Datagram(data: Data(), endpoint: second)])
            XCTAssertEqual(result, .capacity); XCTAssertEqual(created, 1)
        }
    }

    func testSourceEOFAndDeinitializationCancelExactlyOnce() {
        let queue = DispatchQueue(label: "test.udp.eof"), flow = TestDatagramFlow()
        let transport = TestDatagramTransport()
        queue.sync {
            var session: DatagramSession? = DatagramSession(flow: flow, queue: queue, makeTransport: { _ in transport })
            var finishes = 0
            session?.onFinish = { error in XCTAssertNil(error); finishes += 1 }
            session?.start(); flow.emit([Datagram(data: Data(), endpoint: first)])
            flow.emit([])
            XCTAssertEqual(finishes, 1); XCTAssertEqual(transport.cancelCount, 1)
            session = nil
            XCTAssertEqual(flow.cancelCount, 1); XCTAssertEqual(transport.cancelCount, 1)
        }
        let unreadFlow = TestDatagramFlow()
        queue.sync {
            var session: DatagramSession? = DatagramSession(flow: unreadFlow, queue: queue)
            session?.start(); session = nil
            XCTAssertEqual(unreadFlow.cancelCount, 1)
        }
    }

    func testTransportAndFlowFailuresCloseAndReleaseResources() {
        for mode in 0..<5 {
            let queue = DispatchQueue(label: "test.udp.failures"), flow = TestDatagramFlow()
            let transport = TestDatagramTransport()
            transport.deferStart = mode == 0; transport.deferSends = mode == 1; flow.deferWrites = mode == 3
            let session = DatagramSession(flow: flow, queue: queue, makeTransport: { _ in transport })
            var finishes = 0
            queue.sync {
                session.onFinish = { error in XCTAssertEqual(error, .connectionFailed); finishes += 1 }
                session.start()
                if mode == 4 {
                    let read = flow.pendingRead; flow.pendingRead = nil; read?(.failure(.connectionFailed))
                } else {
                    flow.emit([Datagram(data: Data([1]), endpoint: first)])
                    switch mode {
                    case 0: transport.pendingStart?(.failure(.connectionFailed))
                    case 1: transport.sends.removeFirst()(POSIXError(.ENETUNREACH))
                    case 2: transport.emit(nil, complete: false, error: POSIXError(.ECONNREFUSED))
                    default:
                        transport.emit(Data([2])); flow.writes.removeFirst()(POSIXError(.EPIPE))
                    }
                }
                XCTAssertEqual(finishes, 1); XCTAssertEqual(flow.cancelCount, 1)
                XCTAssertEqual(transport.cancelCount, mode == 4 ? 0 : 1)
                session.stop(); XCTAssertEqual(finishes, 1)
            }
        }
    }

    func testCancellationDropsLateStartReadAndWriteCallbacks() {
        let queue = DispatchQueue(label: "test.udp.cancel"), flow = TestDatagramFlow()
        let transport = TestDatagramTransport(); transport.deferStart = true
        var finishes = 0
        let session = DatagramSession(flow: flow, queue: queue, makeTransport: { _ in transport })
        queue.sync {
            session.onFinish = { _ in finishes += 1 }; session.start(); session.start()
            XCTAssertEqual(flow.receiveCount, 1)
            flow.emit([Datagram(data: Data([1]), endpoint: first)])
            session.stop(); session.stop()
            transport.pendingStart?(.success(()))
            session.start()
            XCTAssertTrue(transport.sent.isEmpty); XCTAssertEqual(finishes, 1); XCTAssertEqual(flow.receiveCount, 1)
            XCTAssertEqual(transport.cancelCount, 1)
        }
        let readyFlow = TestDatagramFlow(), readyTransport = TestDatagramTransport()
        readyFlow.deferWrites = true
        let ready = DatagramSession(flow: readyFlow, queue: queue, makeTransport: { _ in readyTransport })
        queue.sync {
            ready.start(); readyFlow.emit([Datagram(data: Data(), endpoint: first)])
            let lateRead = readyTransport.pendingRead
            readyTransport.emit(Data([2]))
            ready.stop(); readyFlow.writes.removeFirst()(nil)
            lateRead?(Data([3]), true, nil)
            XCTAssertEqual(readyFlow.sent.count, 1); XCTAssertEqual(readyTransport.receiveCount, 1)
        }
        let sendingFlow = TestDatagramFlow(), sendingTransport = TestDatagramTransport()
        sendingTransport.deferSends = true
        let sending = DatagramSession(flow: sendingFlow, queue: queue, makeTransport: { _ in sendingTransport })
        queue.sync {
            sending.start(); sendingFlow.emit([Datagram(data: Data([1]), endpoint: first), Datagram(data: Data([2]), endpoint: first)])
            sending.stop(); sendingTransport.sends.removeFirst()(nil)
            XCTAssertEqual(sendingTransport.sent, [Data([1])]); XCTAssertEqual(sendingFlow.receiveCount, 1)
        }
    }

    func testIdleAndConnectDeadlinesReleaseResources() async {
        for connecting in [false, true] {
            let queue = DispatchQueue(label: "test.udp.deadline"), flow = TestDatagramFlow()
            let transport = TestDatagramTransport(); transport.deferStart = connecting
            var config = DatagramConfiguration(); config.connectTimeout = 0.04; config.idleTimeout = connecting ? 2 : 0.04
            let done = expectation(description: "UDP deadline closes")
            let session = DatagramSession(flow: flow, queue: queue, configuration: config, makeTransport: { _ in transport })
            queue.sync {
                session.onFinish = { error in XCTAssertEqual(error, .timedOut); done.fulfill() }
                session.start()
                if connecting { flow.emit([Datagram(data: Data([1]), endpoint: first)]) }
            }
            await fulfillment(of: [done], timeout: 2)
            queue.sync {
                XCTAssertEqual(flow.cancelCount, 1)
                if connecting { XCTAssertEqual(transport.cancelCount, 1); transport.pendingStart?(.success(())); XCTAssertTrue(transport.sent.isEmpty) }
                session.stop()
            }
        }
    }

    func testNativeIPv4UDPTransportPreservesEmptyAndNonemptyDatagrams() async throws {
        try await nativeRoundTrip(ipv6: false, hostString: "127.0.0.1")
    }
    func testNativeIPv6UDPTransportPreservesEmptyAndNonemptyDatagrams() async throws {
        try await nativeRoundTrip(ipv6: true, hostString: "::1")
    }
    private func nativeRoundTrip(ipv6: Bool, hostString: String) async throws {
        let queue = DispatchQueue(label: "test.udp.native"), flow = TestDatagramFlow()
        let fixture = try NativeUDPEchoFixture(ipv6: ipv6, queue: queue)
        let replies = expectation(description: "UDP packets echoed")
        var config = DatagramConfiguration(); config.allowLoopbackForTesting = true
        let endpoint = DatagramEndpoint(host: hostString, port: fixture.port)
        let payloads = [Data(), Data([0, 1, 2, 0, 255]), Data(), Data(repeating: 97, count: 4096),
                        Data(repeating: 123, count: 65_507), Data(), Data([9, 0])]
        replies.expectedFulfillmentCount = payloads.count
        let loopbackInterface = if_nametoindex("lo0")
        XCTAssertNotEqual(loopbackInterface, 0)
        let session = DatagramSession(flow: flow, queue: queue, configuration: config) {
            UDPTransport(endpoint: $0, interfaceIndex: loopbackInterface)
        }
        queue.sync {
            flow.onSend = { _ in replies.fulfill() }
            session.onFinish = { error in if let error { XCTFail("UDP fixture failed: \(error)") } }
            session.start(); flow.emit(payloads.map { Datagram(data: $0, endpoint: endpoint) })
        }
        await fulfillment(of: [replies], timeout: 5)
        queue.sync {
            XCTAssertEqual(flow.sent.map(\.data), payloads)
            XCTAssertEqual(fixture.received, payloads)
            XCTAssertTrue(flow.sent.allSatisfy { $0.endpoint == endpoint })
            session.stop(); fixture.cancel()
        }
    }
}
