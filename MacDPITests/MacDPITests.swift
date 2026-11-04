import XCTest
@testable import MacDPI

private final class FakeEngine: EngineControlling {
    var value = Snapshot()
    var shouldFail = false
    var deferredStart: ((Result<Void, CoreError>) -> Void)?
    var delayStart = false
    var starts = 0
    var stops = 0
    func start(configuration: Configuration, completion: @escaping (Result<Void, CoreError>) -> Void) {
        starts += 1
        if delayStart { deferredStart = completion; return }
        value.state = shouldFail ? .failed : .enabled
        completion(shouldFail ? .failure(.connectionFailed) : .success(()))
    }
    func stop(completion: @escaping () -> Void) { stops += 1; value.state = .disabled; completion() }
    func snapshot(_ completion: @escaping (Snapshot) -> Void) { completion(value) }
}

final class MacDPITests: XCTestCase {
    @MainActor
    func testUIStateAndShutdown() async throws {
        let engine = FakeEngine()
        let model = AppModel(engine: engine, store: MemoryConfigurationStore())
        XCTAssertEqual(model.snapshot.state, .disabled)
        model.enable()
        XCTAssertEqual(model.snapshot.state, .starting)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.snapshot.state, .enabled)
        model.disable()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.snapshot.state, .disabled)
        XCTAssertEqual(engine.starts, 1); XCTAssertEqual(engine.stops, 1)
    }
    @MainActor
    func testDisableDuringStartupIgnoresLateCompletion() async throws {
        let engine = FakeEngine(); engine.delayStart = true
        let model = AppModel(engine: engine, store: MemoryConfigurationStore())
        model.enable(); model.disable()
        engine.deferredStart?(.success(()))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.snapshot.state, .disabled)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(engine.stops, 1)
    }
    @MainActor
    func testFailureNeverShowsEnabled() async throws {
        let engine = FakeEngine(); engine.shouldFail = true
        let model = AppModel(engine: engine, store: MemoryConfigurationStore())
        model.enable()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.snapshot.state, .failed)
        XCTAssertNotNil(model.error)
        model.disable()
    }
    @MainActor
    func testInvalidSettingsNeverStartEngine() {
        let engine = FakeEngine()
        let model = AppModel(engine: engine, store: MemoryConfigurationStore())
        model.configuration.port = 80
        model.enable()
        XCTAssertEqual(engine.starts, 0); XCTAssertNotNil(model.error)
    }
    @MainActor
    func testUnsafeSavedSettingsAreRejected() {
        var unsafe = Configuration(); unsafe.allowLoopbackForTesting = true
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore(unsafe))
        XCTAssertFalse(model.configuration.allowLoopbackForTesting)
        XCTAssertEqual(model.configuration.allowedPorts, [443])
    }
    @MainActor
    func testReadinessReportsLimitations() {
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore())
        model.checkReadiness()
        XCTAssertTrue(model.diagnostics.contains("not automatically verified"))
        XCTAssertTrue(model.diagnostics.contains("not installed"))
    }
}
