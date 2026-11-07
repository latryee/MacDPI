import XCTest
@testable import MacDPICore

func fixture(name: String = "example.test") -> Data {
    func u16(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
    let host = Array(name.utf8)
    let entry = [UInt8(0)] + u16(host.count) + host
    let sni = u16(entry.count) + entry
    let ext = [UInt8(0), 0] + u16(sni.count) + sni
    let body = [UInt8(3), 3] + [UInt8](repeating: 7, count: 32) + [0, 0, 2, 0x13, 1, 1, 0] + u16(ext.count) + ext
    let handshake = [UInt8(1), 0] + u16(body.count) + body
    return Data([22, 3, 1] + u16(handshake.count) + handshake)
}
func deframe(_ data: Data) -> Data {
    var out = Data(), p = 0
    let b = [UInt8](data)
    while p + 5 <= b.count {
        let n = Int(b[p+3])*256 + Int(b[p+4])
        guard p+5+n <= b.count else { break }
        out.append(contentsOf: b[(p+5)..<(p+5+n)]); p += 5+n
    }
    return out
}

final class CoreTests: XCTestCase {
    func testConfigurationBoundsAndRoundTrip() throws {
        let c = Configuration()
        XCTAssertEqual(try c.validated(), c)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(c)), c)
        XCTAssertFalse(try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8)).tunTLSOriginRepair)
        var optedIn = c
        optedIn.tunTLSOriginRepair = true
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(optedIn)), optedIn)
        var bad = c; bad.port = 80; XCTAssertThrowsError(try bad.validated())
        bad = c; bad.maxConnections = 257; XCTAssertThrowsError(try bad.validated())
        bad = c; bad.splitOffset = 0; XCTAssertThrowsError(try bad.validated())
        bad = c; bad.handshakeTimeout = .nan; XCTAssertThrowsError(try bad.validated())
        bad = c; bad.allowedPorts = []; XCTAssertThrowsError(try bad.validated())
        bad = c; bad.idleTimeout = .infinity; XCTAssertThrowsError(try bad.validated())
    }
    func testPersonalTUNAutomaticSetupKeepsOrdinaryDNSAndPreservesManualPreferences() {
        var saved = Configuration()
        saved.profile = .advanced
        saved.dnsMode = .cloudflare
        saved.dnsBypassDomains = ["corp.example"]
        let effective = saved.personalTUNConfiguration
        XCTAssertEqual(effective.profile, .standard)
        XCTAssertEqual(effective.dnsMode, .system)
        XCTAssertTrue(effective.tunTLSOriginRepair)
        XCTAssertEqual(effective.dnsBypassDomains, ["corp.example"])
        XCTAssertEqual(saved.profile, .advanced)
        saved.tunAutomaticConfiguration = false
        XCTAssertEqual(saved.personalTUNConfiguration, saved)
    }
    func testCONNECTParsingAndIPv6() throws {
        XCTAssertNil(try ConnectRequest.parse(Data("CONNECT example.com:443 HTTP/1.1\r\n".utf8)))
        let r = try XCTUnwrap(ConnectRequest.parse(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\n\r\ntrailing".utf8)))
        XCTAssertEqual(r.host, "example.com"); XCTAssertEqual(r.port, 443)
        XCTAssertEqual(try ConnectRequest.parse(Data("CONNECT [2606:4700::1111]:443 HTTP/1.0\r\n\r\n".utf8))?.host, "2606:4700::1111")
    }
    func testCONNECTRejectsSmugglingAndCredentials() {
        for request in ["GET / HTTP/1.1", "CONNECT a:443 HTTP/2", "CONNECT a:0 HTTP/1.1", "CONNECT user@a:443 HTTP/1.1", "CONNECT a:443 HTTP/1.1\r\nContent-Length: 4", "CONNECT a:443 HTTP/1.1\r\nTransfer-Encoding: chunked", "CONNECT a:443 HTTP/1.1\r\nProxy-Authorization: secret", "CONNECT [::1]:443:80 HTTP/1.1", "CONNECT a:443 HTTP/1.1\nBad: x", "CONNECT a:443 HTTP/1.1\r\n Header: x"] {
            XCTAssertThrowsError(try ConnectRequest.parse(Data((request + "\r\n\r\n").utf8)), request)
        }
        XCTAssertThrowsError(try ConnectRequest.parse(Data(repeating: 65, count: 8192)))
    }
    func testPublicDestinationPolicy() {
        for ip in ["127.0.0.1", "10.0.0.1", "192.168.0.1", "172.31.1.1", "169.254.169.254", "100.64.0.1", "224.0.0.1", "::1", "::ffff:127.0.0.1", "fe80::1", "fc00::1", "64:ff9b::7f00:1", "2001:db8::1", "not-an-ip"] {
            XCTAssertFalse(DestinationPolicy.permits(ip), ip)
        }
        for ip in ["1.1.1.1", "8.8.8.8", "2606:4700::1111"] { XCTAssertTrue(DestinationPolicy.permits(ip), ip) }
        XCTAssertTrue(DestinationPolicy.permits("127.0.0.1", allowLoopback: true))
        XCTAssertFalse(DestinationPolicy.permits("192.168.1.1", allowLoopback: true))
    }
    func testEveryPartialClientHelloIsIncomplete() {
        let data = fixture()
        for n in 0..<data.count { XCTAssertEqual(TLSProcessor.inspect(Data(data.prefix(n))), .incomplete) }
        guard case let .clientHello(length, range) = TLSProcessor.inspect(data) else { return XCTFail() }
        XCTAssertEqual(length, data.count)
        XCTAssertEqual(String(decoding: data[range!], as: UTF8.self), "example.test")
    }
    func testStandardSplitsInsideServerNameAndPreservesTranscript() {
        let data = fixture()
        let result = TLSProcessor.transform(data, profile: .standard)
        XCTAssertTrue(result.transformed); XCTAssertEqual(result.data.count, data.count + 5)
        XCTAssertEqual(deframe(result.data), deframe(data))
        guard case let .clientHello(_, range) = TLSProcessor.inspect(data) else { return XCTFail() }
        let split = Int(result.data[3])*256 + Int(result.data[4]) + 5
        XCTAssertTrue(range!.contains(split))
    }
    func testAdvancedOffsetsPreserveTranscriptAndTail() {
        let data = fixture()
        for offset in [1, 2, 32, 16000] {
            let result = TLSProcessor.transform(data + Data([23,3,3,0,1,42]), profile: .advanced, offset: offset)
            XCTAssertTrue(result.transformed)
            XCTAssertEqual(deframe(result.data), deframe(data) + Data([42]))
        }
    }
    func testCompatibilityIsIdentity() {
        let data = fixture()
        XCTAssertEqual(TLSProcessor.transform(data, profile: .compatibility).data, data)
    }
    func testUnsupportedAndMalformedTLSIsIdentity() {
        var malformed = fixture(); malformed[8] = 0
        for data in [Data([23,3,3,0,1,0]), Data([22,3,3,255,255]), malformed, Data("HTTP/1.1".utf8)] {
            XCTAssertEqual(TLSProcessor.inspect(data), .passthrough)
            XCTAssertEqual(TLSProcessor.transform(data, profile: .standard).data, data)
        }
    }
    func testInitialFlightOneByteAtATime() {
        var processor = InitialFlightProcessor(configuration: Configuration())
        let input = fixture()
        var output = Data()
        for byte in input { if let result = processor.consume(Data([byte])) { output.append(result.data) } }
        XCTAssertTrue(processor.decided); XCTAssertEqual(deframe(output), deframe(input))
        XCTAssertEqual(processor.consume(Data([9,8,7]))?.data, Data([9,8,7]))
    }
    func testIncompleteEOFFlushesUnchanged() {
        var processor = InitialFlightProcessor(configuration: Configuration())
        let data = Data(fixture().prefix(20))
        XCTAssertNil(processor.consume(data))
        XCTAssertEqual(processor.consume(Data(), eof: true)?.data, data)
    }
    func testBoundedPrefixWithLargePipelinedTail() {
        let hello = fixture()
        let tail = Data(repeating: 23, count: 50_000)
        var processor = InitialFlightProcessor(configuration: Configuration())
        let result = processor.consume(hello + tail)!
        XCTAssertEqual(result.data.suffix(tail.count), tail)
        XCTAssertEqual(result.data.count, hello.count + tail.count + 5)
    }
    func testDeterministicUntrustedInputStress() {
        var seed: UInt64 = 42
        for n in 0..<4000 {
            let count = n % 1024
            var bytes = [UInt8](); bytes.reserveCapacity(count)
            for _ in 0..<count { seed = seed &* 6364136223846793005 &+ 1; bytes.append(UInt8(truncatingIfNeeded: seed >> 32)) }
            let data = Data(bytes)
            _ = TLSProcessor.inspect(data)
            let result = TLSProcessor.transform(data, profile: .standard)
            if !result.transformed { XCTAssertEqual(result.data, data) }
            _ = try? ConnectRequest.parse(data)
        }
    }
}
