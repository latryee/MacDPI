import XCTest
@testable import MacDPICore

private func dnsAnswer(host: String = "example.com", type: UInt16 = 1, address: [UInt8] = [1, 1, 1, 1], ttl: UInt32 = 60) -> Data {
    var query = [UInt8](try! DNSMessage.query(host: host, type: type))
    query[2] = 0x81; query[3] = 0x80; query[7] = 1
    query += [0xc0, 0x0c, UInt8(type >> 8), UInt8(type & 255), 0, 1,
              UInt8(ttl >> 24), UInt8((ttl >> 16) & 255), UInt8((ttl >> 8) & 255), UInt8(ttl & 255), 0, UInt8(address.count)] + address
    return Data(query)
}

private final class FixtureDNSProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var payload = Data()
    static var status = 200
    static var mime = "application/dns-message"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.lock.withLock { (Self.payload, Self.status, Self.mime) }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.1, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": fixture.2])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for start in stride(from: 0, to: fixture.0.count, by: 1024) {
            client?.urlProtocol(self, didLoad: Data(fixture.0[start..<min(start+1024, fixture.0.count)]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HTTPSResolverTests: XCTestCase {
    func testWireQueryAndCompressedAnswer() throws {
        let query = try DNSMessage.query(host: "example.com", type: 1)
        XCTAssertEqual(query.count, 29)
        XCTAssertEqual(try DNSMessage.parse(dnsAnswer(), host: "example.com", type: 1).addresses, ["1.1.1.1"])
        let ipv6: [UInt8] = [0x26, 0x06, 0x47, 0x00, 0x47, 0x00] + [UInt8](repeating: 0, count: 8) + [0x11, 0x11]
        XCTAssertEqual(try DNSMessage.parse(dnsAnswer(type: 28, address: ipv6), host: "example.com", type: 28).addresses, ["2606:4700:4700::1111"])
    }
    func testUntrustedAnswersAndInvalidNamesAreRejected() throws {
        for host in ["", "bad..name", "-bad.com", "a/b.com", String(repeating: "a", count: 64)+".com", "é.com"] {
            XCTAssertThrowsError(try DNSMessage.query(host: host, type: 1))
        }
        XCTAssertThrowsError(try DNSMessage.parse(dnsAnswer(), host: "other.com", type: 1))
        XCTAssertThrowsError(try DNSMessage.parse(dnsAnswer(address: [127, 0, 0, 1]), host: "example.com", type: 1))
        XCTAssertThrowsError(try DNSMessage.parse(dnsAnswer(address: [10, 0, 0, 1]), host: "example.com", type: 1))
        var malformed = dnsAnswer(); malformed[29] = 0xc0; malformed[30] = 29
        XCTAssertThrowsError(try DNSMessage.parse(malformed, host: "example.com", type: 1))
        malformed = dnsAnswer(); malformed[3] = 0x83
        XCTAssertThrowsError(try DNSMessage.parse(malformed, host: "example.com", type: 1))
        malformed = dnsAnswer(); malformed[2] |= 2
        XCTAssertThrowsError(try DNSMessage.parse(malformed, host: "example.com", type: 1))
        let good = dnsAnswer()
        for n in 0..<good.count { XCTAssertThrowsError(try DNSMessage.parse(Data(good.prefix(n)), host: "example.com", type: 1)) }
        XCTAssertThrowsError(try DNSMessage.parse(Data(repeating: 0, count: 32_769), host: "example.com", type: 1))
    }
    func testCNAMEChainAndUnrelatedAnswer() throws {
        var data = [UInt8](try DNSMessage.query(host: "example.com", type: 1))
        data[2] = 0x81; data[3] = 0x80; data[7] = 2
        // example.com CNAME edge.example.com, then the matching A answer.
        data += [0xc0, 12, 0, 5, 0, 1, 0, 0, 0, 30, 0, 7, 4, 101, 100, 103, 101, 0xc0, 12]
        data += [0xc0, 41, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 1, 1, 1]
        let answer = try DNSMessage.parse(Data(data), host: "example.com", type: 1)
        XCTAssertEqual(answer.addresses, ["1.1.1.1"]); XCTAssertEqual(answer.ttl, 30)
        // An address owned by a different name must never be used.
        data = [UInt8](dnsAnswer())
        data.replaceSubrange(29..<31, with: [4, 101, 118, 105, 108, 0])
        XCTAssertEqual(try DNSMessage.parse(Data(data), host: "example.com", type: 1).addresses, [])
    }
    func testCoalescingCacheAndNoSystemFallback() async {
        let delivered = expectation(description: "Both callers delivered"); delivered.expectedFulfillmentCount = 2
        let lock = NSLock(); var calls = 0
        let resolver = HTTPSResolver { query, completion in
            lock.withLock { calls += 1 }
            let type = query.last == 1 ? UInt16(query[query.count-3]) : 1
            completion(.success(type == 28 ? dnsAnswer(type: 28, address: [0x26, 6, 0x47, 0, 0x47, 0] + [UInt8](repeating: 0, count: 8) + [0x11, 0x11]) : dnsAnswer()))
            return ResolutionTicket()
        }
        for _ in 0..<2 {
            resolver.resolve("example.com") { result in
                XCTAssertEqual(try? result.get().first, "1.1.1.1"); delivered.fulfill()
            }
        }
        await fulfillment(of: [delivered], timeout: 2)
        let cached = expectation(description: "Cached result")
        resolver.resolve("example.com") { _ in cached.fulfill() }
        await fulfillment(of: [cached], timeout: 2)
        XCTAssertEqual(lock.withLock { calls }, 2)
        resolver.shutdown()
        let failed = HTTPSResolver { _, completion in completion(.failure(.resolutionFailed)); return ResolutionTicket() }
        let failure = expectation(description: "Failure without fallback")
        failed.resolve("example.com") { result in
            if case .success = result { XCTFail("Unexpected fallback") }; failure.fulfill()
        }
        await fulfillment(of: [failure], timeout: 2); failed.shutdown()
    }
    func testCancellationAbortsRequestsAndStaleResultsDoNotAffectNewLookup() async {
        let lock = NSLock(); var completions = [DNSHTTPTransport.Completion](); var cancelled = 0
        let firstSubmitted = expectation(description: "First queries submitted"); firstSubmitted.expectedFulfillmentCount = 2
        let submitted = expectation(description: "Replacement queries submitted"); submitted.expectedFulfillmentCount = 2
        let resolver = HTTPSResolver { _, completion in
            let count = lock.withLock { completions.append(completion); return completions.count }
            if count <= 2 { firstSubmitted.fulfill() } else { submitted.fulfill() }
            let ticket = ResolutionTicket(); ticket.onCancel { lock.withLock { cancelled += 1 } }; return ticket
        }
        let first = resolver.resolve("example.com") { _ in XCTFail("Cancelled result delivered") }
        // Enqueue cancellation after requests, then a replacement for the same name.
        await fulfillment(of: [firstSubmitted], timeout: 2)
        first.cancel()
        let done = expectation(description: "New result delivered")
        resolver.resolve("example.com") { result in XCTAssertEqual(try? result.get().first, "1.1.1.1"); done.fulfill() }
        await fulfillment(of: [submitted], timeout: 2)
        let callbacks = lock.withLock { completions }
        callbacks[0](.success(dnsAnswer(address: [8, 8, 8, 8]))); callbacks[1](.failure(.resolutionFailed))
        callbacks[2](.success(dnsAnswer())); callbacks[3](.failure(.resolutionFailed))
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(lock.withLock { cancelled }, 2); resolver.shutdown()
    }
    func testOldConfigurationMigratesWithoutOptingIntoCloudflare() throws {
        let old = Data(#"{"port":8181,"profile":"advanced","splitOffset":17}"#.utf8)
        let config = try JSONDecoder().decode(Configuration.self, from: old)
        XCTAssertEqual(config.port, 8181); XCTAssertEqual(config.profile, .advanced)
        XCTAssertEqual(config.splitOffset, 17); XCTAssertEqual(config.dnsMode, .system)
    }
    func testCancellationHandlerRunsOnceIncludingLateInstallation() {
        let ticket = ResolutionTicket(); var calls = 0
        ticket.onCancel { calls += 1 }; ticket.cancel(); ticket.cancel(); XCTAssertEqual(calls, 1)
        let late = ResolutionTicket(); late.cancel(); late.onCancel { calls += 1 }; XCTAssertEqual(calls, 2)
    }
    func testDNSParserBoundedMutationCorpus() {
        let valid = [UInt8](dnsAnswer())
        for index in valid.indices {
            for byte: UInt8 in [0, 63, 192, 255] {
                var bytes = valid; bytes[index] = byte
                _ = try? DNSMessage.parse(Data(bytes), host: "example.com", type: 1)
            }
        }
        var seed: UInt64 = 0x4d6163445049
        for _ in 0..<1000 {
            seed = seed &* 6364136223846793005 &+ 1
            let count = Int(seed % 512)
            var bytes = [UInt8](); bytes.reserveCapacity(count)
            for _ in 0..<count { seed = seed &* 6364136223846793005 &+ 1; bytes.append(UInt8(truncatingIfNeeded: seed >> 32)) }
            _ = try? DNSMessage.parse(Data(bytes), host: "example.com", type: 1)
        }
    }
    func testHTTPTransportRejectsWrongTypeStatusAndOversize() async {
        for (status, mime, size, succeeds) in [(200, "application/dns-message", 20, true),
                                             (200, "text/html", 20, false),
                                             (503, "application/dns-message", 20, false),
                                             (200, "application/dns-message", 33_000, false)] {
            FixtureDNSProtocol.lock.withLock {
                FixtureDNSProtocol.status = status; FixtureDNSProtocol.mime = mime
                FixtureDNSProtocol.payload = Data(repeating: 1, count: size)
            }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureDNSProtocol.self]
            let transport = DNSHTTPTransport(configuration: config)
            let done = expectation(description: "Bounded HTTP transport")
            _ = transport.request(Data([1])) { result in
                switch result {
                case .success(let data): XCTAssertTrue(succeeds); XCTAssertEqual(data.count, size)
                case .failure: XCTAssertFalse(succeeds)
                }
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 3); transport.shutdown()
        }
    }
}
