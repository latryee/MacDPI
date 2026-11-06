import XCTest
@testable import MacDPICore

final class ProxySessionTests: XCTestCase {
    private let token = "fixture-token-used-only-in-tests"

    func testMissingOrWrongCredentialsNeverReachResolver() {
        for authorization in [nil, basic("wrong-token")] {
            let queue = DispatchQueue(label: "test.proxy.auth"), client = FixtureByteStream()
            let resolver = FixtureProxyResolver { _ in XCTFail("Unauthenticated DNS lookup") }
            let session = ProxySession(client: client, queue: queue, configuration: Configuration(),
                                       resolver: resolver, authenticationToken: token) { _, _ in
                XCTFail("Unauthenticated upstream connection")
                return FixtureByteStream()
            }
            queue.sync {
                session.start()
                client.emit(request(authorization))
                let reply = client.writes.first.map { String(decoding: $0.data, as: UTF8.self) }
                XCTAssertTrue(reply?.hasPrefix("HTTP/1.1 407 ") == true)
                XCTAssertTrue(reply?.contains("Proxy-Authenticate: Basic realm=\"MacDPI\"") == true)
                XCTAssertTrue(client.cancelled)
            }
        }
    }

    func testAuthenticatedConnectForwardsOnlyTunnelBytes() async {
        let queue = DispatchQueue(label: "test.proxy.auth.forward")
        let client = FixtureByteStream(), upstream = FixtureByteStream()
        let resolver = FixtureProxyResolver { XCTAssertEqual($0, "example.com") }
        let forwarded = expectation(description: "Forwarded tunnel bytes")
        let payload = Data([0, 255, 1, 2, 3])
        var configuration = Configuration()
        configuration.profile = .compatibility
        let session = ProxySession(client: client, queue: queue, configuration: configuration,
                                   resolver: resolver, authenticationToken: token) { host, port in
            XCTAssertEqual(host, "1.1.1.1")
            XCTAssertEqual(port, 443)
            return upstream
        }
        queue.sync {
            upstream.didWrite = { forwarded.fulfill() }
            session.start()
            client.emit(request(basic(token)) + payload, eof: true)
        }
        await fulfillment(of: [forwarded], timeout: 2)
        queue.sync {
            XCTAssertEqual(client.writes.first?.data, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            XCTAssertEqual(upstream.writes.map(\.data), [payload])
            XCTAssertEqual(upstream.writes.first?.final, true)
            session.stop()
        }
    }

    func testDuplicateProxyCredentialsAreRejectedEvenWhenAuthenticationEnabled() {
        let header = "Proxy-Authorization: \(basic(token))\r\n"
        let duplicate = Data("CONNECT example.com:443 HTTP/1.1\r\n\(header)\(header)\r\n".utf8)
        XCTAssertThrowsError(try ConnectRequest.parse(duplicate, allowProxyAuthentication: true))
    }

    func testTransparentServerFirstConnectionOutlivesTLSHandshakeDeadline() async {
        let queue = DispatchQueue(label: "test.proxy.server-first")
        let client = FixtureByteStream(), upstream = FixtureByteStream()
        let ready = expectation(description: "Upstream connected"), finished = expectation(description: "Both sides drained")
        var base = Configuration()
        base.handshakeTimeout = 0.05
        let configuration = TransparentPolicy.configuration(for: 5222, base: base)
        let session = ProxySession(client: client, queue: queue, configuration: configuration,
                                   resolver: FixtureProxyResolver { XCTAssertEqual($0, "1.1.1.1") }) { host, port in
            XCTAssertEqual(host, "1.1.1.1")
            XCTAssertEqual(port, 5222)
            return upstream
        }
        queue.sync {
            upstream.didStart = { ready.fulfill() }
            session.onFinish = { XCTAssertNil($0); finished.fulfill() }
            session.start(destination: ("1.1.1.1", 5222))
        }
        await fulfillment(of: [ready], timeout: 2)
        try? await Task.sleep(nanoseconds: 150_000_000)
        queue.sync {
            let greeting = Data("server greeting".utf8), response = Data("client response".utf8)
            upstream.emit(greeting, eof: true)
            client.emit(response, eof: true)
            XCTAssertEqual(client.writes.map(\.data), [greeting])
            XCTAssertEqual(upstream.writes.map(\.data), [response])
            XCTAssertEqual(client.writes.first?.final, true)
            XCTAssertEqual(upstream.writes.first?.final, true)
        }
        await fulfillment(of: [finished], timeout: 2)
    }

    private func request(_ authorization: String?) -> Data {
        let header = authorization.map { "Proxy-Authorization: \($0)\r\n" } ?? ""
        return Data("CONNECT example.com:443 HTTP/1.1\r\n\(header)\r\n".utf8)
    }

    private func basic(_ secret: String) -> String {
        "Basic " + Data("macdpi:\(secret)".utf8).base64EncodedString()
    }
}

private final class FixtureProxyResolver: HostResolving {
    let didResolve: (String) -> Void
    init(_ didResolve: @escaping (String) -> Void) { self.didResolve = didResolve }

    func resolve(_ host: String, completion: @escaping (Result<[String], CoreError>) -> Void) -> ResolutionTicket {
        didResolve(host)
        completion(.success(["1.1.1.1"]))
        return ResolutionTicket()
    }

}

private final class FixtureByteStream: OutboundByteStream {
    private var read: ((Data?, Bool, Error?) -> Void)?
    var writes = [(data: Data, final: Bool)]()
    var didStart: (() -> Void)?
    var didWrite: (() -> Void)?
    var cancelled = false

    func start(queue: DispatchQueue, completion: @escaping (Result<Void, CoreError>) -> Void) {
        completion(.success(()))
        didStart?()
    }

    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void) { read = completion }

    func send(_ data: Data, final: Bool, completion: @escaping (Error?) -> Void) {
        writes.append((data, final))
        completion(nil)
        didWrite?()
    }

    func cancel() { cancelled = true; read = nil }

    func emit(_ bytes: Data, eof: Bool = false) {
        let callback = read
        read = nil
        callback?(bytes, eof, nil)
    }
}
