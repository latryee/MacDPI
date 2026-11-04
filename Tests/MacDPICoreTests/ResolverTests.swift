import XCTest
@testable import MacDPICore

final class ResolverTests: XCTestCase {
    func testQueuedCancellationSkipsLookupAndRunningCancellationDropsResult() async {
        let entered = expectation(description: "First lookup started")
        let after = expectation(description: "Queue drained")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = [String]()
        let resolver = SystemResolver { host in
            lock.lock(); calls.append(host); lock.unlock()
            if host == "first.test" {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
            return .success(["1.1.1.1"])
        }
        let first = resolver.resolve("first.test") { _ in XCTFail("Cancelled in-flight result delivered") }
        await fulfillment(of: [entered], timeout: 1)
        let second = resolver.resolve("cancelled.test") { _ in XCTFail("Cancelled queued result delivered") }
        first.cancel(); second.cancel(); release.signal()
        resolver.resolve("after.test") { _ in after.fulfill() }
        await fulfillment(of: [after], timeout: 2)
        let actual = lock.withLock { calls }
        XCTAssertEqual(actual, ["first.test", "after.test"])
    }
    func testLiteralAddressDoesNotInvokeDNS() {
        let resolver = SystemResolver { _ in XCTFail("Literal address invoked DNS"); return .failure(.resolutionFailed) }
        var result: [String]?
        resolver.resolve("127.0.0.1") { result = try? $0.get() }
        XCTAssertEqual(result, ["127.0.0.1"])
    }
    func testResolverFailureIsDelivered() async {
        let delivered = expectation(description: "DNS failure")
        let resolver = SystemResolver { _ in .failure(.resolutionFailed) }
        resolver.resolve("failed.test") { result in
            if case .success = result { XCTFail("Failed resolution reported success") }
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 1)
    }
}
