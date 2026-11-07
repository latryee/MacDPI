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

@MainActor
private final class FakePersonalTUN: PersonalTUNControlling {
    var phase: PersonalTUNPhase = .disabled
    var detail = "Fixture status"
    let recoveryCommand: String? = "fixture recovery"
    var resourceProcessIDs: [Int32] = [1, 2]
    var changed: (() -> Void)?
    var configuration: Configuration?
    var stopCompletion: ((Bool) -> Void)?

    func setPhase(_ next: PersonalTUNPhase) {
        phase = next
        changed?()
    }

    func start(_ configuration: Configuration) {
        self.configuration = configuration
        setPhase(.authorization)
    }

    func stop(completion: ((Bool) -> Void)?) {
        stopCompletion = completion
        setPhase(.stopping)
    }
}

final class MacDPITests: XCTestCase {
    @MainActor
    func testPersonalTunnelUsageSamplesOnlyTheActiveSession() async {
        let tun = FakePersonalTUN()
        var reads: [Int32: UInt64] = [:]
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore(), mode: .personalTUN,
                             personalTUNController: tun, resourceReader: { pid in
            reads[pid, default: 0] += 1
            return ProcessResourceReading(identity: UInt64(pid), cpuNanoseconds: reads[pid]! * 1_000_000,
                                          residentBytes: UInt64(pid) * 1024)
        }, resourceMeasurementDelay: { await Task.yield() })
        model.measureTUNUsage()
        XCTAssertTrue(reads.isEmpty)
        model.enable()
        model.measureTUNUsage()
        XCTAssertTrue(reads.isEmpty)
        tun.setPhase(.active)
        model.measureTUNUsage()
        for _ in 0..<20 where model.measuringTUNUsage { await Task.yield() }
        XCTAssertFalse(model.measuringTUNUsage)
        XCTAssertEqual(reads, [1: 2, 2: 2])
        XCTAssertEqual(model.personalTUNUsage?.residentBytes, 3072)
        XCTAssertNotNil(model.personalTUNUsage?.cpuPercent)
        XCTAssertTrue(model.diagnostics.contains("Session helper excluded"))
    }

    @MainActor
    func testPersonalTunnelUsageCannotReappearAfterDisable() async {
        let tun = FakePersonalTUN()
        var resume: CheckedContinuation<Void, Never>?
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore(), mode: .personalTUN,
                             personalTUNController: tun,
                             resourceReader: { ProcessResourceReading(identity: UInt64($0), cpuNanoseconds: 1, residentBytes: 1024) },
                             resourceMeasurementDelay: { await withCheckedContinuation { resume = $0 } })
        tun.setPhase(.active)
        model.measureTUNUsage()
        for _ in 0..<20 where resume == nil { await Task.yield() }
        XCTAssertTrue(model.measuringTUNUsage)
        XCTAssertNotNil(resume)
        model.disable()
        tun.setPhase(.disabled)
        resume?.resume()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(model.personalTUNUsage)
        XCTAssertFalse(model.measuringTUNUsage)
        XCTAssertFalse(model.diagnostics.contains("CPU ·"))
    }

    @MainActor
    func testPersonalTunnelUsageRejectsChangedOrUnavailableProcesses() async {
        let tun = FakePersonalTUN()
        var resume: CheckedContinuation<Void, Never>?
        var readable = false
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore(), mode: .personalTUN,
                             personalTUNController: tun,
                             resourceReader: { readable ? ProcessResourceReading(identity: UInt64($0), cpuNanoseconds: 1, residentBytes: 1024) : nil },
                             resourceMeasurementDelay: { await withCheckedContinuation { resume = $0 } })
        tun.setPhase(.active)
        model.measureTUNUsage()
        XCTAssertNil(model.personalTUNUsage)
        XCTAssertFalse(model.measuringTUNUsage)
        XCTAssertTrue(model.tunUsageDetail.contains("unavailable"))
        readable = true
        model.measureTUNUsage()
        for _ in 0..<20 where resume == nil { await Task.yield() }
        XCTAssertNotNil(resume)
        tun.resourceProcessIDs = [3, 4]
        resume?.resume()
        for _ in 0..<20 where model.measuringTUNUsage { await Task.yield() }
        XCTAssertNil(model.personalTUNUsage)
        XCTAssertFalse(model.measuringTUNUsage)
        XCTAssertTrue(model.tunUsageDetail.contains("session changed"))
    }

    @MainActor
    func testPersonalTunnelUsesVerifiedStateAndKeepsProxyIdle() {
        let tun = FakePersonalTUN(), proxy = FakeEngine()
        let model = AppModel(engine: proxy, store: MemoryConfigurationStore(), mode: .personalTUN, personalTUNController: tun)
        model.configuration.dnsMode = .cloudflare
        model.configuration.profile = .compatibility
        model.enable()
        XCTAssertEqual(model.personalTUNPhase, .authorization)
        XCTAssertEqual(tun.configuration?.dnsMode, .system)
        XCTAssertEqual(tun.configuration?.profile, .standard)
        XCTAssertEqual(tun.configuration?.tunTLSOriginRepair, true)
        XCTAssertEqual(model.configuration.profile, .compatibility)
        XCTAssertFalse(model.isEnabled)
        tun.setPhase(.configuring)
        XCTAssertFalse(model.isEnabled)
        tun.setPhase(.active)
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(proxy.starts, 0)
        model.integrationMode = .localProxy
        XCTAssertEqual(model.integrationMode, .personalTUN)
        model.disable()
        tun.setPhase(.restoring)
        XCTAssertFalse(model.canToggleEngine)
        tun.setPhase(.recovery)
        XCTAssertEqual(model.recoveryCommand, "fixture recovery")
        XCTAssertFalse(model.isEnabled)
    }

    @MainActor
    func testPersonalTunnelQuitWaitsForShutdownAttempt() {
        let tun = FakePersonalTUN()
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore(), mode: .personalTUN, personalTUNController: tun)
        model.enable()
        tun.setPhase(.active)
        var quit: Bool?
        model.terminate { quit = $0 }
        XCTAssertNil(quit)
        tun.setPhase(.recovery)
        tun.stopCompletion?(false)
        XCTAssertEqual(quit, true)
        XCTAssertNotNil(model.error)
    }
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

@MainActor
private final class FakeIntegrationDriver: IntegrationDriving {
    var observationChanged: ((IntegrationObservation) -> Void)?
    var value = IntegrationObservation()
    var inspections = 0, installs = 0, starts = 0, stops = 0, removals = 0
    var startError: IntegrationFailure?
    var stopError: IntegrationFailure?
    var delayedStart: ((Result<IntegrationObservation, IntegrationFailure>) -> Void)?
    var delayStart = false
    var returnUninspectedStop = false
    init() { value.extensionState = .enabled }
    func inspect(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) { inspections += 1; completion(.success(value)) }
    func install(explicitConsent: Bool, completion: @escaping (Result<IntegrationInstallResult, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        installs += 1; completion(.success(.installed))
    }
    func start(configuration: Configuration, explicitConsent: Bool, completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        starts += 1
        if delayStart { delayedStart = completion; return }
        if let startError { completion(.failure(startError)); return }
        value.configurationPresent = true; value.ownConfigurationCount = 1
        value.connection = .connected; value.provider = ProviderStatusMessage(isEnabled: true)
        value.dns = configuration.dnsMode == .cloudflare ? .init(state: .encryptedActive, detail: "Fixture encrypted DNS") : .system
        completion(.success(value))
    }
    func stop(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        stops += 1
        if let stopError { completion(.failure(stopError)); return }
        value.connection = .disconnected; value.provider = ProviderStatusMessage(isEnabled: false)
        if returnUninspectedStop { value.systemStateInspected = false }
        completion(.success(value))
    }
    func remove(explicitConsent: Bool, completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        removals += 1; value.configurationPresent = false; value.ownConfigurationCount = 0; value.extensionState = .absent
        completion(.success(value))
    }
}

extension MacDPITests {
    @MainActor
    func testInjectedEngineSelectsIsolatedLocalDiagnosticMode() {
        let engine = FakeEngine(), driver = FakeIntegrationDriver()
        let model = AppModel(engine: engine, store: MemoryConfigurationStore(), integrationDriver: driver)
        XCTAssertEqual(model.integrationMode, .localProxy)
        XCTAssertEqual(driver.inspections, 0); XCTAssertEqual(driver.starts, 0)
    }
    @MainActor
    func testTransparentEnableRequiresReviewBeforeAnyMutation() {
        let engine = FakeEngine(), driver = FakeIntegrationDriver()
        let model = AppModel(engine: engine, store: MemoryConfigurationStore(), integrationDriver: driver, mode: .transparent)
        XCTAssertEqual(driver.inspections, 1); XCTAssertEqual(driver.starts, 0)
        model.enable()
        XCTAssertEqual(model.pendingConsent, .enable)
        XCTAssertEqual(driver.starts, 0); XCTAssertEqual(engine.starts, 0)
        model.confirmIntegrationConsent()
        XCTAssertNil(model.pendingConsent); XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.statusTitle, "Transparent routing active")
        XCTAssertEqual(driver.starts, 1); XCTAssertEqual(engine.starts, 0)
        model.disable()
        XCTAssertFalse(model.isEnabled); XCTAssertEqual(driver.stops, 1)
    }
    @MainActor
    func testCancelledSetupDoesNotInstallOrStart() {
        let engine = FakeEngine(), driver = FakeIntegrationDriver()
        let model = AppModel(engine: engine, store: MemoryConfigurationStore(), integrationDriver: driver, mode: .transparent)
        model.setupIntegration(); model.cancelIntegrationConsent(); model.confirmIntegrationConsent()
        XCTAssertEqual(driver.starts, 0); XCTAssertEqual(driver.installs, 0); XCTAssertEqual(engine.starts, 0)
    }
    @MainActor
    func testIntegrationFailureNeverFallsBackToLocalProxy() {
        let engine = FakeEngine(), driver = FakeIntegrationDriver(); driver.startError = .permissionDenied
        let model = AppModel(engine: engine, store: MemoryConfigurationStore(), integrationDriver: driver, mode: .transparent)
        model.enable(); model.confirmIntegrationConsent()
        XCTAssertFalse(model.isEnabled); XCTAssertEqual(model.integrationStatus.phase, .failed)
        XCTAssertEqual(engine.starts, 0); XCTAssertNotNil(model.error)
    }
    @MainActor
    func testEmergencyStopCancelsDelayedEnable() {
        let engine = FakeEngine(), driver = FakeIntegrationDriver(); driver.delayStart = true
        let model = AppModel(engine: engine, store: MemoryConfigurationStore(), integrationDriver: driver, mode: .transparent)
        model.enable(); model.confirmIntegrationConsent(); model.emergencyStop()
        var late = driver.value; late.connection = .connected; late.configurationPresent = true
        late.ownConfigurationCount = 1; late.provider = ProviderStatusMessage(isEnabled: true)
        driver.delayedStart?(.success(late))
        XCTAssertFalse(model.isEnabled); XCTAssertFalse(model.busy)
        XCTAssertEqual(driver.stops, 1); XCTAssertEqual(engine.starts, 0)
    }
    @MainActor
    func testRemovalRequiresItsOwnConsent() {
        let driver = FakeIntegrationDriver()
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore(), integrationDriver: driver, mode: .transparent)
        model.requestIntegrationRemoval()
        XCTAssertEqual(model.pendingConsent, .remove); XCTAssertEqual(driver.removals, 0)
        model.confirmIntegrationConsent()
        XCTAssertEqual(driver.removals, 1); XCTAssertEqual(driver.stops, 1)
    }
    @MainActor
    func testModeCannotChangeWhileIntegrationIsActive() {
        let driver = FakeIntegrationDriver()
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore(), integrationDriver: driver, mode: .transparent)
        model.enable(); model.confirmIntegrationConsent()
        model.integrationMode = .localProxy
        XCTAssertEqual(model.integrationMode, .transparent); XCTAssertNotNil(model.error)
        model.disable()
    }
    @MainActor
    func testQuitIsCancelledWhenSystemStopCannotBeVerified() {
        let driver = FakeIntegrationDriver(); driver.stopError = .stopUnverified
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore(), integrationDriver: driver, mode: .transparent)
        var mayQuit: Bool?
        model.terminate { mayQuit = $0 }
        XCTAssertEqual(mayQuit, false); XCTAssertNotNil(model.error)
    }
    @MainActor
    func testDeactivationRejectsMissingConsentAndUnrelatedIdentifierWithoutOSRequest() {
        var result: IntegrationFailure?
        TransparentIntegrationController.requestOwnedDeactivation(identifier: TransparentIntegrationController.identifier, explicitConsent: false) {
            if case .failure(let error) = $0 { result = error }
        }
        XCTAssertEqual(result, .consentRequired)
        TransparentIntegrationController.requestOwnedDeactivation(identifier: "com.example.unrelated", explicitConsent: true) {
            if case .failure(let error) = $0 { result = error }
        }
        XCTAssertEqual(result, .unavailable)
    }
    @MainActor
    func testNeverMutatedUnsupportedBuildMayQuitWithoutClaimingGlobalDisconnect() {
        let driver = FakeIntegrationDriver(); driver.returnUninspectedStop = true
        let model = AppModel(engine: FakeEngine(), store: MemoryConfigurationStore(), integrationDriver: driver, mode: .transparent)
        var mayQuit: Bool?
        model.terminate { mayQuit = $0 }
        XCTAssertEqual(mayQuit, true)
        XCTAssertEqual(model.integrationStatus.phase, .unavailable)
        XCTAssertTrue(model.statusDetail.contains("not inspected"))
        XCTAssertEqual(driver.starts, 0); XCTAssertEqual(driver.installs, 0)
    }

    @MainActor
    func testLocalReviewAdapterStopDoesNotNeedNetworkPreferences() throws {
        guard IntegrationSigningPreflight.issue() != nil else { throw XCTSkip("This safety check applies to an unsupported/local-review build only.") }
        let driver = TransparentIntegrationController()
        var outcome: Result<IntegrationObservation, IntegrationFailure>?
        driver.stop { outcome = $0 }
        let observation = try XCTUnwrap(outcome).get()
        XCTAssertFalse(observation.systemStateInspected)
        XCTAssertTrue(observation.connection.isStopped)
        XCTAssertNotNil(observation.preflightIssue)
    }

    @MainActor
    func testAuthorizedScopeNeedsOnlyOneClickOnSubsequentEnable() {
        let driver = FakeIntegrationDriver(), store = MemoryConfigurationStore()
        let model = AppModel(engine: FakeEngine(), store: store, integrationDriver: driver, mode: .transparent)
        model.enable(); XCTAssertEqual(model.pendingConsent, .enable)
        model.confirmIntegrationConsent(); model.disable()
        model.enable()
        XCTAssertNil(model.pendingConsent); XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(driver.starts, 2)
        model.disable()
    }
    @MainActor
    func testChangedDNSPrivacyScopeRequiresAnotherReview() {
        let driver = FakeIntegrationDriver(), store = MemoryConfigurationStore()
        let model = AppModel(engine: FakeEngine(), store: store, integrationDriver: driver, mode: .transparent)
        model.enable(); model.confirmIntegrationConsent(); model.disable()
        model.configuration.dnsMode = .cloudflare
        model.enable()
        XCTAssertEqual(model.pendingConsent, .enable); XCTAssertEqual(driver.starts, 1)
        model.confirmIntegrationConsent(); model.disable()
        model.configuration.dnsBypassDomains = ["corp.example"]
        model.enable()
        XCTAssertEqual(model.pendingConsent, .enable); XCTAssertEqual(driver.starts, 2)
        model.cancelIntegrationConsent()
    }
    @MainActor
    func testPersistedConsentNeverStartsIntegrationOnLaunchAndTLSChangesNeedNoNewReview() {
        var config = Configuration(); config.profile = .compatibility
        let store = MemoryConfigurationStore(config, integrationConsent: IntegrationConsentScope(configuration: config))
        let driver = FakeIntegrationDriver()
        let model = AppModel(engine: FakeEngine(), store: store, integrationDriver: driver, mode: .transparent)
        XCTAssertEqual(driver.starts, 0); XCTAssertNil(model.pendingConsent); XCTAssertFalse(model.isEnabled)
        model.configuration.profile = .advanced; model.configuration.splitOffset = 64
        model.enable()
        XCTAssertEqual(driver.starts, 1); XCTAssertNil(model.pendingConsent)
        model.disable()
    }
    @MainActor
    func testConfirmedRemovalRevokesRememberedConsent() {
        let config = Configuration(), driver = FakeIntegrationDriver()
        let store = MemoryConfigurationStore(config, integrationConsent: IntegrationConsentScope(configuration: config))
        let model = AppModel(engine: FakeEngine(), store: store, integrationDriver: driver, mode: .transparent)
        model.requestIntegrationRemoval(); model.confirmIntegrationConsent()
        XCTAssertNil(store.loadIntegrationConsent())
        model.enable()
        XCTAssertEqual(model.pendingConsent, .enable)
        XCTAssertEqual(driver.starts, 0)
    }

    @MainActor
    func testNativeTestHostWithoutInjectedEngineUsesIsolatedLocalMode() throws {
        guard AppModel.isIsolatedLaunch else { throw XCTSkip("Requires XCTest host detection.") }
        let model = AppModel(store: MemoryConfigurationStore())
        XCTAssertEqual(model.integrationMode, .localProxy)
        XCTAssertFalse(model.isEnabled)
        XCTAssertNil(model.pendingConsent)
    }

}
