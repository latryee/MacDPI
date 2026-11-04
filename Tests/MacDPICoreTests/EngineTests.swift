import XCTest
import Darwin
@testable import MacDPICore

final class EngineTests: XCTestCase {
    private func unusedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoreError.connectionFailed }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw -> Int32 in
                guard Darwin.bind(fd, raw, size) == 0 else { return -1 }
                return getsockname(fd, raw, &size)
            }
        }
        guard result == 0 else { throw CoreError.connectionFailed }
        return UInt16(bigEndian: addr.sin_port)
    }
    private func start(_ engine: ProxyEngine, configuration: Configuration) async -> Result<Void, CoreError> {
        await withCheckedContinuation { continuation in engine.start(configuration: configuration) { continuation.resume(returning: $0) } }
    }
    private func stop(_ engine: ProxyEngine) async {
        await withCheckedContinuation { continuation in engine.stop { continuation.resume() } }
    }
    private func snapshot(_ engine: ProxyEngine) async -> Snapshot {
        await withCheckedContinuation { continuation in engine.snapshot { continuation.resume(returning: $0) } }
    }
    func testStartStopRestartAndDisabledSnapshot() async throws {
        let engine = ProxyEngine()
        var config = Configuration(); config.port = try unusedPort()
        for _ in 0..<3 {
            if case .failure(let error) = await start(engine, configuration: config) { return XCTFail(error.rawValue) }
            let enabled = await snapshot(engine)
            XCTAssertEqual(enabled.state, .enabled)
            await stop(engine)
            let disabled = await snapshot(engine)
            XCTAssertEqual(disabled.state, .disabled); XCTAssertEqual(disabled.activeConnections, 0)
        }
    }
    func testInvalidStartAndDuplicateStartFailSafely() async throws {
        let engine = ProxyEngine()
        var config = Configuration(); config.port = 80
        if case .success = await start(engine, configuration: config) { XCTFail("Invalid port accepted") }
        config.port = try unusedPort()
        if case .failure = await start(engine, configuration: config) { XCTFail("Start failed") }
        if case .success = await start(engine, configuration: config) { XCTFail("Duplicate start accepted") }
        let state = await snapshot(engine)
        XCTAssertEqual(state.state, .enabled)
        await stop(engine)
    }
    func testStartCancellationLeavesNoListener() async throws {
        let engine = ProxyEngine()
        var config = Configuration(); config.port = try unusedPort()
        let callback = expectation(description: "Start resolves on stop")
        engine.start(configuration: config) { _ in callback.fulfill() }
        await stop(engine)
        await fulfillment(of: [callback], timeout: 3)
        let state = await snapshot(engine)
        XCTAssertEqual(state.state, .disabled)
        if case .failure = await start(engine, configuration: config) { XCTFail("Cancelled listener retained its port") }
        await stop(engine)
    }
}
