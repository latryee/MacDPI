import XCTest
@testable import MacDPICore

private func dnsQuery(_ name: String = "example.com", type: UInt16 = 1, id: UInt16 = 0x1234) -> Data {
    var data = Data([UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    for label in name.split(separator: ".") { data.append(UInt8(label.utf8.count)); data.append(contentsOf: label.utf8) }
    data.append(contentsOf: [0, UInt8(type >> 8), UInt8(type & 255), 0, 1]); return data
}
private func dnsResponse(_ query: Data, code: UInt8 = 0, answerBytes: Int = 0) -> Data {
    var data = query; data[2] = 0x81; data[3] = 0x80 | code
    if answerBytes > 0 {
        data[7] = 1
        data.append(contentsOf: [0xc0, 12, 0, 16, 0, 1, 0, 0, 0, 60, UInt8(answerBytes >> 8), UInt8(answerBytes & 255)])
        data.append(Data(repeating: 65, count: answerBytes))
    }
    return data
}
private final class DNSFixtureStream: ByteStream {
    var pendingRead: ((Data?, Bool, Error?) -> Void)?
    var sent = [Data]()
    var cancelled = 0
    var deferSend = false
    var pendingWrite: ((Error?) -> Void)?
    var onWrite: (() -> Void)?
    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void) { XCTAssertNil(pendingRead); pendingRead = completion }
    func send(_ data: Data, final: Bool, completion: @escaping (Error?) -> Void) {
        sent.append(data); onWrite?()
        if deferSend { pendingWrite = completion } else { completion(nil) }
    }
    func emit(_ data: Data, eof: Bool = false) { let callback = pendingRead; pendingRead = nil; callback?(data, eof, nil) }
    func cancel() { cancelled += 1; pendingRead = nil }
}
private final class DNSFixtureDatagrams: DatagramFlow {
    var pending: ((Result<[Datagram], CoreError>) -> Void)?
    var sent = [Datagram](); var cancelled = 0
    var onWrite: (() -> Void)?
    func receive(_ completion: @escaping (Result<[Datagram], CoreError>) -> Void) { pending = completion }
    func send(_ datagram: Datagram, completion: @escaping (Error?) -> Void) { sent.append(datagram); onWrite?(); completion(nil) }
    func emit(_ data: [Datagram]) { let callback = pending; pending = nil; callback?(.success(data)) }
    func cancel() { cancelled += 1; pending = nil }
}

final class DNSRoutingTests: XCTestCase {
    func testGeneralTypesAndEnvelopeValidation() throws {
        for type: UInt16 in [1, 28, 16, 33, 64, 65, 2, 255] {
            let query = dnsQuery("_game._udp.example.com", type: type)
            let parsed = try DNSPacket(query, response: false)
            XCTAssertEqual(parsed.name, "_game._udp.example.com"); XCTAssertEqual(parsed.type, type)
            XCTAssertEqual(try parsed.reply(DNSPacket(dnsResponse(query), response: true), udp: false), dnsResponse(query))
        }
        XCTAssertEqual(try DNSPacket(dnsQuery("", type: 2), response: false).name, "")
        let valid = dnsQuery()
        for count in 0..<valid.count { XCTAssertThrowsError(try DNSPacket(Data(valid.prefix(count)), response: false)) }
        var bad = valid; bad[12] = 0xc0; bad[13] = 12
        XCTAssertThrowsError(try DNSPacket(bad, response: false))
        bad = valid; bad[5] = 2; XCTAssertThrowsError(try DNSPacket(bad, response: false))
        bad = valid; bad[2] = 0x81; XCTAssertThrowsError(try DNSPacket(bad, response: false))
        bad = valid; bad.append(0); XCTAssertThrowsError(try DNSPacket(bad, response: false))
        XCTAssertThrowsError(try DNSPacket(Data(repeating: 0, count: 32769), response: false))
    }
    func testReplyRequiresExactQuestionAndTransaction() throws {
        let query = try DNSPacket(dnsQuery(), response: false)
        for other in [dnsQuery("other.com"), dnsQuery(type: 28), dnsQuery(id: 7)] {
            XCTAssertThrowsError(try query.reply(DNSPacket(dnsResponse(other), response: true), udp: false))
        }
        let nx = dnsResponse(query.data, code: 3)
        XCTAssertEqual(try query.reply(DNSPacket(nx, response: true), udp: true), nx)
        let failure = try DNSPacket(query.failureReply(), response: true)
        XCTAssertEqual(failure.flags & 15, 2); XCTAssertEqual(failure.identifier, query.identifier)
    }
    func testUDPSizeLimitsRequestTCPRetryAndLeaveTCPUnmodified() throws {
        let bytes = dnsQuery(), response = dnsResponse(bytes, answerBytes: 1200)
        let query = try DNSPacket(bytes, response: false), parsed = try DNSPacket(response, response: true)
        let udp = try query.reply(parsed, udp: true)
        XCTAssertEqual(udp.count, query.questionEnd); XCTAssertNotEqual(try DNSPacket(udp, response: true).flags & 0x0200, 0)
        XCTAssertEqual(try query.reply(parsed, udp: false), response)
        var edns = bytes; edns[11] = 1; edns.append(contentsOf: [0, 0, 41, 16, 0, 0, 0, 0, 0, 0, 0])
        let withEDNS = try DNSPacket(edns, response: false)
        XCTAssertEqual(withEDNS.udpLimit, 4096)
        XCTAssertEqual(try withEDNS.reply(parsed, udp: true), response)
    }
    func testLocalAndSplitDomainPolicyDoesNotUseSubstringGuessing() {
        let policy = DNSRoutingPolicy(originalResolverDomains: ["corp.example", ".Office.Internal.", ""])
        for name in ["printer", "host.local", "localhost", "device.home.arpa", "1.0.0.127.in-addr.arpa", "x.ip6.arpa", "corp.example", "srv.corp.example", "srv.office.internal"] {
            XCTAssertTrue(policy.usesOriginalResolver(name), name)
        }
        for name in ["example.com", "evilcorp.example", "corp.example.evil.com"] { XCTAssertFalse(policy.usesOriginalResolver(name), name) }
    }
    func testEncryptedFailureNeverCallsOriginalResolver() {
        var original = 0, encrypted = 0
        let router = DNSQueryRouter(policy: DNSRoutingPolicy(), encrypted: { _, callback in encrypted += 1; callback(.failure(.resolutionFailed)); return ResolutionTicket() }, original: { _, _ in original += 1; return ResolutionTicket() })
        router.exchange(dnsQuery(), udp: true) { if case .success = $0 { XCTFail("Unexpected fallback") } }
        XCTAssertEqual(encrypted, 1); XCTAssertEqual(original, 0)
    }
    func testExplicitExceptionsPreserveOriginalAndDNSBytes() {
        var original = 0, encrypted = 0
        let router = DNSQueryRouter(policy: DNSRoutingPolicy(originalResolverDomains: ["corp.example"]), encrypted: { bytes, callback in encrypted += 1; callback(.success(dnsResponse(bytes))); return ResolutionTicket() }, original: { bytes, callback in original += 1; callback(.success(dnsResponse(bytes))); return ResolutionTicket() })
        for (name, bound) in [("srv.corp.example", false), ("example.com", true), ("example.com", false)] {
            let query = dnsQuery(name, type: 33)
            router.exchange(query, preserveOriginalInterface: bound, udp: false) { XCTAssertEqual(try? $0.get(), dnsResponse(query)) }
        }
        XCTAssertEqual(original, 2); XCTAssertEqual(encrypted, 1)
    }
    func testCancellationAbortsChildAndSuppressesLateResult() {
        var cancelled = 0; var callback: ((Result<Data, CoreError>) -> Void)?
        let router = DNSQueryRouter(policy: DNSRoutingPolicy(), encrypted: { _, completion in
            callback = completion; let ticket = ResolutionTicket(); ticket.onCancel { cancelled += 1 }; return ticket
        }, original: { _, _ in XCTFail("Unexpected original resolver"); return ResolutionTicket() })
        let ticket = router.exchange(dnsQuery(), udp: true) { _ in XCTFail("Cancelled result delivered") }
        ticket.cancel(); callback?(.success(dnsResponse(dnsQuery())))
        XCTAssertEqual(cancelled, 1)
    }
    func testTCPFramingPartialReadsPipeliningAndBounds() throws {
        let query = dnsQuery(), frame = try DNSStreamFramer.frame(query)
        var framer = DNSStreamFramer()
        try framer.append(Data(frame.prefix(1))); XCTAssertNil(try framer.next())
        try framer.append(Data(frame.dropFirst().prefix(4))); XCTAssertNil(try framer.next())
        try framer.append(Data(frame.dropFirst(5)) + frame)
        XCTAssertEqual(try framer.next(), query); XCTAssertEqual(try framer.next(), query); XCTAssertTrue(framer.isEmpty)
        try framer.append(Data([0, 1])); XCTAssertThrowsError(try framer.next())
        var huge = DNSStreamFramer(); XCTAssertThrowsError(try huge.append(Data(repeating: 0, count: 98_307)))
    }
    func testTCPBackpressureOrdersPipelinedRepliesAndCancelsPendingQuery() async throws {
        let queue = DispatchQueue(label: "test.dns.tcp"), source = DNSFixtureStream()
        var queries = [Data](); var pending: ((Result<Data, CoreError>) -> Void)?; var cancelled = 0
        let router = DNSQueryRouter(policy: DNSRoutingPolicy(), encrypted: { bytes, callback in
            queries.append(bytes); pending = callback; let ticket = ResolutionTicket(); ticket.onCancel { cancelled += 1 }; return ticket
        }, original: { _, _ in XCTFail("Unexpected original resolver"); return ResolutionTicket() })
        let firstWrite = expectation(description: "First reply"), secondQuery = expectation(description: "Second query pending")
        let first = dnsQuery(id: 1), second = dnsQuery(id: 2)
        var session: DNSStreamSession? = DNSStreamSession(client: source, queue: queue, router: router)
        queue.sync {
            source.deferSend = true; source.onWrite = { firstWrite.fulfill() }
            session?.start(); source.emit(try! DNSStreamFramer.frame(first) + DNSStreamFramer.frame(second))
            XCTAssertEqual(queries, [first]); pending?(.success(dnsResponse(first)))
        }
        await fulfillment(of: [firstWrite], timeout: 2)
        queue.sync {
            XCTAssertEqual(queries, [first]); source.onWrite = nil
            let sent = source.pendingWrite; source.pendingWrite = nil; sent?(nil)
            XCTAssertEqual(queries, [first, second]); secondQuery.fulfill()
            session?.stop(); pending?(.success(dnsResponse(second))); session = nil
            XCTAssertEqual(source.cancelled, 1); XCTAssertEqual(cancelled, 1)
        }
        await fulfillment(of: [secondQuery], timeout: 1)
    }
    func testUDPFailureReturnsServfailAndPreservesIPv6ResolverSource() async throws {
        let queue = DispatchQueue(label: "test.dns.udp"), source = DNSFixtureDatagrams()
        let written = expectation(description: "SERVFAIL datagram")
        let endpoint = DatagramEndpoint(host: "fd00::53", port: 53)
        var session: DNSDatagramSession? = DNSDatagramSession(flow: source, queue: queue) { target in
            XCTAssertEqual(target, endpoint)
            return DNSQueryRouter(policy: DNSRoutingPolicy(), encrypted: { _, callback in callback(.failure(.resolutionFailed)); return ResolutionTicket() }, original: { _, _ in XCTFail("Failure fallback"); return ResolutionTicket() })
        }
        queue.sync { source.onWrite = { written.fulfill() }; session?.start(); source.emit([Datagram(data: dnsQuery(type: 65), endpoint: endpoint)]) }
        await fulfillment(of: [written], timeout: 2)
        try queue.sync {
            XCTAssertEqual(source.sent.count, 1); XCTAssertEqual(source.sent[0].endpoint, endpoint)
            XCTAssertEqual(try DNSPacket(source.sent[0].data, response: true).flags & 15, 2)
            source.emit([]); session = nil; XCTAssertEqual(source.cancelled, 1)
        }
    }
    func testDNSDeadlineCancelsExchangeAndIncompleteTCPIsRejected() async {
        let queue = DispatchQueue(label: "test.dns.deadline"), source = DNSFixtureStream()
        var cancelled = 0
        let router = DNSQueryRouter(policy: DNSRoutingPolicy(), encrypted: { _, _ in let t = ResolutionTicket(); t.onCancel { cancelled += 1 }; return t }, original: { _, _ in ResolutionTicket() })
        let done = expectation(description: "DNS deadline")
        let session = DNSStreamSession(client: source, queue: queue, router: router, timeout: 0.03)
        queue.sync { session.onFinish = { XCTAssertEqual($0, .timedOut); done.fulfill() }; session.start(); source.emit(try! DNSStreamFramer.frame(dnsQuery())) }
        await fulfillment(of: [done], timeout: 2)
        queue.sync { XCTAssertEqual(cancelled, 1); XCTAssertEqual(source.cancelled, 1) }
        let partial = DNSFixtureStream(), rejected = expectation(description: "Incomplete EOF")
        let other = DNSStreamSession(client: partial, queue: queue, router: router)
        queue.sync { other.onFinish = { XCTAssertEqual($0, .invalidRequest); rejected.fulfill() }; other.start(); partial.emit(Data([0]), eof: true) }
        await fulfillment(of: [rejected], timeout: 1)
    }
    func testDNSParserMutationCorpusHasBoundedFailure() {
        let valid = [UInt8](dnsResponse(dnsQuery(), answerBytes: 50))
        for index in valid.indices {
            for value: UInt8 in [0, 63, 192, 255] { var bytes = valid; bytes[index] = value; _ = try? DNSPacket(Data(bytes), response: true) }
        }
    }
    func testTransparentPolicyPreservesNumericEndpointsAndExcludesUnsafeFlows() {
        XCTAssertTrue(TransparentPolicy.shouldHandle(endpoint: .init(host: "1.1.1.1", port: 5222), sourceIdentifier: "example.app", isBound: false, hasInterface: false))
        XCTAssertTrue(TransparentPolicy.shouldHandle(endpoint: .init(host: "2606:4700::1111", port: 3478), sourceIdentifier: nil, isBound: true, hasInterface: true))
        for target in [DatagramEndpoint(host: "10.0.0.1", port: 443), .init(host: "127.0.0.1", port: 8080), .init(host: "example.com", port: 443), .init(host: "1.1.1.1", port: 53)] {
            XCTAssertFalse(TransparentPolicy.shouldHandle(endpoint: target, sourceIdentifier: nil, isBound: false, hasInterface: false))
        }
        XCTAssertFalse(TransparentPolicy.shouldHandle(endpoint: .init(host: "1.1.1.1", port: 443), sourceIdentifier: "io.github.latryee.MacDPI.DNSProxy", isBound: false, hasInterface: false))
        XCTAssertFalse(TransparentPolicy.shouldHandle(endpoint: .init(host: "1.1.1.1", port: 443), sourceIdentifier: nil, isBound: true, hasInterface: false))
        XCTAssertEqual(TransparentPolicy.configuration(for: 5222, base: Configuration()).profile, .compatibility)
        XCTAssertEqual(TransparentPolicy.configuration(for: 8443, base: Configuration()).profile, .standard)
        XCTAssertEqual(TransparentPolicy.configuration(for: 5222, base: Configuration()).allowedPorts, [5222])
    }
}
