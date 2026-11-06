import XCTest
@testable import MacDPICore

@MainActor
private final class FixtureIntegrationDriver: IntegrationDriving {
    var observationChanged: ((IntegrationObservation) -> Void)?
    var observation = IntegrationObservation()
    var inspectionFailure: IntegrationFailure?
    var deferInspection = false
    var deferredInspections = [(Result<IntegrationObservation, IntegrationFailure>) -> Void]()
    var startFailure: IntegrationFailure?
    var stopFailure: IntegrationFailure?
    var installResult: IntegrationInstallResult = .installed
    var deferStart = false
    var deferStop = false
    var deferredStop: ((Result<IntegrationObservation, IntegrationFailure>) -> Void)?
    var deferredStart: ((Result<IntegrationObservation, IntegrationFailure>) -> Void)?
    var readyAfterStart = true
    var encryptedDNSReady = true
    var dnsAfterStart: IntegrationDNSStatus?
    var stopObservation: IntegrationObservation?
    var installs = 0, starts = 0, stops = 0, removals = 0
    func inspect(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        if deferInspection { deferredInspections.append(completion); return }
        completion(inspectionFailure.map(Result.failure) ?? .success(observation))
    }
    func install(explicitConsent: Bool, completion: @escaping (Result<IntegrationInstallResult, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        installs += 1
        if case .installed = installResult { observation.extensionState = .enabled }
        if case .awaitingApproval = installResult { observation.extensionState = .awaitingApproval }
        completion(.success(installResult))
    }
    func start(configuration: Configuration, explicitConsent: Bool, completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        starts += 1
        if deferStart { deferredStart = completion; return }
        if let startFailure { completion(.failure(startFailure)); return }
        observation.configurationPresent = true; observation.ownConfigurationCount = 1
        observation.configurationCurrent = true
        observation.connection = readyAfterStart ? .connected : .connecting
        observation.provider = ProviderStatusMessage(isEnabled: readyAfterStart)
        observation.dns = configuration.dnsMode == .cloudflare && encryptedDNSReady
            ? IntegrationDNSStatus(state: .encryptedActive, detail: "Fixture encrypted DNS") : .system
        if let dnsAfterStart {
            observation.dns = dnsAfterStart
            if [.awaitingApproval, .restartRequired].contains(dnsAfterStart.state) {
                observation.connection = .disconnected; observation.provider = ProviderStatusMessage(isEnabled: false)
            }
        }
        completion(.success(observation))
    }
    func stop(completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        stops += 1
        if deferStop { deferredStop = completion; return }
        if let stopFailure { completion(.failure(stopFailure)); return }
        observation.connection = .disconnected; observation.provider = ProviderStatusMessage(isEnabled: false)
        observation.dns = .system
        completion(.success(stopObservation ?? observation))
    }
    func remove(explicitConsent: Bool, completion: @escaping (Result<IntegrationObservation, IntegrationFailure>) -> Void) {
        guard explicitConsent else { completion(.failure(.consentRequired)); return }
        removals += 1; observation.configurationPresent = false; observation.ownConfigurationCount = 0
        observation.extensionState = .absent; completion(.success(observation))
    }
}

final class IntegrationLifecycleTests: XCTestCase {
    @MainActor
    func testInspectNeverInstallsOrStarts() {
        let driver = FixtureIntegrationDriver(), lifecycle = IntegrationLifecycle(driver: FixtureIntegrationDriver())
        let observed = IntegrationLifecycle(driver: driver)
        observed.refresh()
        XCTAssertEqual(observed.status.phase, .permissionRequired)
        XCTAssertEqual(driver.installs, 0); XCTAssertEqual(driver.starts, 0)
        XCTAssertEqual(lifecycle.status.phase, .disabled)
    }
    @MainActor
    func testEnableWithoutConsentCannotMutateMachine() {
        let driver = FixtureIntegrationDriver(), config = Configuration()
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: config, explicitConsent: false)
        XCTAssertEqual(lifecycle.status.phase, .permissionRequired)
        XCTAssertEqual(driver.installs, 0); XCTAssertEqual(driver.starts, 0)
    }
    @MainActor
    func testMissingSigningOrBundlePreflightBlocksActivation() {
        let driver = FixtureIntegrationDriver(); driver.observation.preflightIssue = "Fixture unsigned build"
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        XCTAssertEqual(lifecycle.status.phase, .unavailable)
        XCTAssertEqual(driver.installs, 0); XCTAssertEqual(driver.starts, 0)
    }
    @MainActor
    func testActualReadyObservationIsRequiredForActive() {
        let driver = FixtureIntegrationDriver(), lifecycle = IntegrationLifecycle(driver: FixtureIntegrationDriver())
        let model = IntegrationLifecycle(driver: driver)
        driver.readyAfterStart = false
        model.enable(configuration: Configuration(), explicitConsent: true)
        XCTAssertEqual(model.status.phase, .failed); XCTAssertFalse(model.status.isEnabled)
        XCTAssertEqual(lifecycle.status.phase, .disabled)
    }
    @MainActor
    func testInstalledIntegrationStartsAndStopsWithVerification() {
        let driver = FixtureIntegrationDriver(); driver.observation.extensionState = .enabled
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        XCTAssertEqual(lifecycle.status.phase, .active); XCTAssertTrue(lifecycle.status.isEnabled)
        XCTAssertEqual(driver.installs, 0); XCTAssertEqual(driver.starts, 1)
        var confirmed = false
        lifecycle.disable { confirmed = (try? $0.get()) != nil }
        XCTAssertTrue(confirmed); XCTAssertEqual(lifecycle.status.phase, .disabled); XCTAssertEqual(driver.stops, 1)
    }
    @MainActor
    func testApprovalAndRestartNeverImplyActive() {
        for state: IntegrationInstallResult in [.awaitingApproval, .restartRequired] {
            let driver = FixtureIntegrationDriver(); driver.installResult = state
            let lifecycle = IntegrationLifecycle(driver: driver)
            lifecycle.enable(configuration: Configuration(), explicitConsent: true)
            XCTAssertFalse(lifecycle.status.isEnabled); XCTAssertEqual(driver.starts, 0)
            XCTAssertTrue([IntegrationPhase.awaitingApproval, .restartRequired].contains(lifecycle.status.phase))
        }
    }
    @MainActor
    func testDuplicateConfigurationsAreNeverSilentlyReplaced() {
        let driver = FixtureIntegrationDriver(); driver.observation.ownConfigurationCount = 2
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        XCTAssertEqual(lifecycle.status.phase, .failed); XCTAssertEqual(driver.starts, 0)
    }
    @MainActor
    func testDisableDuringStartDropsStaleCompletion() {
        let driver = FixtureIntegrationDriver(); driver.deferStart = true
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        XCTAssertEqual(lifecycle.status.phase, .starting)
        lifecycle.disable()
        var stale = driver.observation; stale.connection = .connected; stale.configurationPresent = true
        stale.ownConfigurationCount = 1; stale.provider = ProviderStatusMessage(isEnabled: true)
        driver.deferredStart?(.success(stale))
        XCTAssertEqual(lifecycle.status.phase, .disabled); XCTAssertFalse(lifecycle.status.isEnabled)
    }
    @MainActor
    func testDuplicateEnableWhileStartingDoesNotDuplicateOSRequests() {
        let driver = FixtureIntegrationDriver(); driver.deferStart = true
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        XCTAssertEqual(driver.starts, 1); XCTAssertEqual(driver.installs, 1)
        lifecycle.disable()
    }
    @MainActor
    func testEncryptedDNSCannotReportActiveWithoutSystemDNSSupport() {
        let driver = FixtureIntegrationDriver(); driver.encryptedDNSReady = false
        let lifecycle = IntegrationLifecycle(driver: driver)
        var config = Configuration(); config.dnsMode = .cloudflare
        lifecycle.enable(configuration: config, explicitConsent: true)
        XCTAssertEqual(lifecycle.status.phase, .failed); XCTAssertFalse(lifecycle.status.isEnabled)
        XCTAssertEqual(driver.stops, 1); XCTAssertEqual(lifecycle.status.detail, IntegrationFailure.dnsUnavailable.rawValue)
    }
    @MainActor
    func testUnverifiedStopDoesNotClaimDisabled() {
        let driver = FixtureIntegrationDriver(), lifecycle = IntegrationLifecycle(driver: FixtureIntegrationDriver())
        let model = IntegrationLifecycle(driver: driver)
        model.enable(configuration: Configuration(), explicitConsent: true)
        driver.stopFailure = .stopUnverified
        model.disable()
        XCTAssertEqual(model.status.phase, .failed)
        XCTAssertTrue(model.status.detail.contains("not confirmed"))
        XCTAssertEqual(lifecycle.status.phase, .disabled)
    }
    @MainActor
    func testRemovalRequiresConsentAndStopsBeforeRemoving() {
        let driver = FixtureIntegrationDriver(), model = IntegrationLifecycle(driver: FixtureIntegrationDriver())
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.remove(explicitConsent: false)
        XCTAssertEqual(driver.removals, 0)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        lifecycle.remove(explicitConsent: true)
        XCTAssertEqual(driver.stops, 1); XCTAssertEqual(driver.removals, 1)
        XCTAssertEqual(lifecycle.status.phase, .permissionRequired)
        XCTAssertEqual(model.status.phase, .disabled)
    }
    @MainActor
    func testRestartInspectionAdoptsOnlyRealReadyProvider() {
        let driver = FixtureIntegrationDriver()
        driver.observation.extensionState = .enabled; driver.observation.configurationPresent = true
        driver.observation.ownConfigurationCount = 1; driver.observation.connection = .connected
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.refresh(); XCTAssertNotEqual(lifecycle.status.phase, .active)
        driver.observation.provider = ProviderStatusMessage(isEnabled: true)
        lifecycle.refresh(); XCTAssertEqual(lifecycle.status.phase, .active)
        XCTAssertEqual(driver.starts, 0)
    }
    @MainActor
    func testNetworkLossAndUnexpectedLateConnectionAreVisible() {
        let driver = FixtureIntegrationDriver(), model = IntegrationLifecycle(driver: FixtureIntegrationDriver())
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        driver.observation.connection = .reasserting; driver.observationChanged?(driver.observation)
        XCTAssertEqual(lifecycle.status.phase, .reconnecting)
        lifecycle.disable()
        driver.observation.connection = .connected; driver.observation.provider = ProviderStatusMessage(isEnabled: true)
        driver.observationChanged?(driver.observation)
        XCTAssertEqual(lifecycle.status.phase, .failed); XCTAssertFalse(lifecycle.status.isEnabled)
        XCTAssertEqual(model.status.phase, .disabled)
    }
    func testProviderControlReplyRejectsIncompatibleOrUnboundedState() throws {
        var reply = ProviderStatusMessage(isEnabled: false)
        XCTAssertTrue(reply.isDrained)
        reply.activeUDPFlows = 1; XCTAssertFalse(reply.isDrained)
        reply.activeTCPFlows = -1; XCTAssertFalse(reply.isValid)
        reply.activeTCPFlows = 0; reply.protocolVersion = 2; XCTAssertFalse(reply.isValid)
        let good = ProviderStatusMessage(isEnabled: true, activeTCPFlows: 1)
        XCTAssertEqual(try JSONDecoder().decode(ProviderStatusMessage.self, from: JSONEncoder().encode(good)), good)
    }
    @MainActor
    func testApprovedInstallationContinuesOnlyTheConsentedEnable() {
        let driver = FixtureIntegrationDriver(); driver.installResult = .awaitingApproval
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        driver.observation.extensionState = .enabled
        driver.observationChanged?(driver.observation)
        XCTAssertEqual(lifecycle.status.phase, .active)
        XCTAssertEqual(driver.starts, 1)
        lifecycle.disable()
    }
    @MainActor
    func testDisableCancelsPendingApprovalWithoutStartingLater() {
        let driver = FixtureIntegrationDriver(); driver.installResult = .awaitingApproval
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        lifecycle.disable()
        driver.observation.extensionState = .enabled
        driver.observationChanged?(driver.observation)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertEqual(lifecycle.status.phase, .disabled)
    }
    @MainActor
    func testChangedExtensionRequiresConsentedReplacement() {
        let driver = FixtureIntegrationDriver(); driver.observation.extensionState = .enabled
        driver.observation.extensionCurrent = false
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        XCTAssertEqual(driver.installs, 1)
        lifecycle.disable()
    }
    @MainActor
    func testStaleConfigurationInspectionDoesNotRepairPreferences() {
        let driver = FixtureIntegrationDriver(); driver.observation.extensionState = .enabled
        driver.observation.configurationPresent = true; driver.observation.configurationCurrent = false
        driver.observation.ownConfigurationCount = 1
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.refresh()
        XCTAssertEqual(lifecycle.status.phase, .permissionRequired)
        XCTAssertEqual(driver.starts, 0); XCTAssertEqual(driver.installs, 0)
    }
    @MainActor
    func testRestartCannotAdoptEncryptedConfigurationWithoutDNSReadiness() {
        let driver = FixtureIntegrationDriver()
        driver.observation.extensionState = .enabled; driver.observation.connection = .connected
        driver.observation.configurationPresent = true; driver.observation.ownConfigurationCount = 1
        driver.observation.provider = ProviderStatusMessage(isEnabled: true)
        driver.observation.requiresEncryptedDNS = true
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.refresh()
        XCTAssertEqual(lifecycle.status.phase, .failed)
        XCTAssertEqual(lifecycle.status.detail, IntegrationFailure.dnsUnavailable.rawValue)
        XCTAssertEqual(driver.starts, 0); XCTAssertEqual(driver.stops, 0)
    }
    @MainActor
    func testStartDeadlineRollsBackAndDropsDelayedReadyReply() async throws {
        let driver = FixtureIntegrationDriver(); driver.deferStart = true
        let lifecycle = IntegrationLifecycle(driver: driver, operationTimeout: 0.02)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(lifecycle.status.phase, .failed)
        XCTAssertEqual(lifecycle.status.detail, IntegrationFailure.timedOut.rawValue)
        XCTAssertEqual(driver.stops, 1)
        var ready = driver.observation; ready.connection = .connected; ready.provider = ProviderStatusMessage(isEnabled: true)
        driver.deferredStart?(.success(ready))
        XCTAssertEqual(lifecycle.status.phase, .failed)
    }
    @MainActor
    func testStopDeadlineFailsOnceAndIgnoresLateCompletion() async throws {
        let driver = FixtureIntegrationDriver(); driver.deferStop = true
        let lifecycle = IntegrationLifecycle(driver: driver, operationTimeout: 0.02)
        var completions = 0
        lifecycle.disable { _ in completions += 1 }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(lifecycle.status.phase, .failed)
        XCTAssertEqual(completions, 1)
        driver.deferredStop?(.success(IntegrationObservation()))
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(lifecycle.status.phase, .failed)
    }
    @MainActor
    func testRepeatedRemovalDoesNotDuplicateOSRequests() {
        let driver = FixtureIntegrationDriver(); driver.deferStop = true
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.remove(explicitConsent: true); lifecycle.remove(explicitConsent: true)
        XCTAssertEqual(driver.stops, 1)
        driver.deferredStop?(.success(IntegrationObservation()))
        XCTAssertEqual(driver.removals, 1)
    }
    @MainActor
    func testInvalidLoopbackExceptionNeverReachesDriver() {
        let driver = FixtureIntegrationDriver(), lifecycle = IntegrationLifecycle(driver: FixtureIntegrationDriver())
        let model = IntegrationLifecycle(driver: driver)
        var config = Configuration(); config.allowLoopbackForTesting = true
        model.enable(configuration: config, explicitConsent: true)
        XCTAssertEqual(model.status.phase, .failed)
        XCTAssertEqual(driver.starts, 0); XCTAssertEqual(driver.installs, 0)
        XCTAssertEqual(lifecycle.status.phase, .disabled)
    }

    @MainActor
    func testPendingDNSApprovalDoesNotStartATimeoutRollbackOrClaimActive() async throws {
        let driver = FixtureIntegrationDriver()
        driver.dnsAfterStart = .init(state: .awaitingApproval, detail: "Approve DNS extension in System Settings, then Enable again.")
        let lifecycle = IntegrationLifecycle(driver: driver, operationTimeout: 0.02)
        var config = Configuration(); config.dnsMode = .cloudflare
        lifecycle.enable(configuration: config, explicitConsent: true)
        XCTAssertEqual(lifecycle.status.phase, .awaitingApproval); XCTAssertFalse(lifecycle.status.isEnabled)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(lifecycle.status.phase, .awaitingApproval); XCTAssertEqual(driver.stops, 0)
        driver.dnsAfterStart = nil
        lifecycle.enable(configuration: config, explicitConsent: true)
        XCTAssertEqual(lifecycle.status.phase, .active)
        lifecycle.disable()
    }
    @MainActor
    func testDNSRestartRequirementNeverClaimsActive() {
        let driver = FixtureIntegrationDriver()
        driver.dnsAfterStart = .init(state: .restartRequired, detail: "Restart required for DNS extension.")
        let lifecycle = IntegrationLifecycle(driver: driver)
        var config = Configuration(); config.dnsMode = .cloudflare
        lifecycle.enable(configuration: config, explicitConsent: true)
        XCTAssertEqual(lifecycle.status.phase, .restartRequired); XCTAssertFalse(lifecycle.status.isEnabled)
        XCTAssertEqual(driver.stops, 0)
    }
    @MainActor
    func testUnknownDNSRestorationCannotProveDisabled() {
        let driver = FixtureIntegrationDriver()
        var stopped = IntegrationObservation(); stopped.connection = .disconnected
        stopped.dns = .init(state: .unknown, detail: "No restoration acknowledgement")
        driver.stopObservation = stopped
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.disable()
        XCTAssertEqual(lifecycle.status.phase, .failed)
    }
    @MainActor
    func testProviderWithRemainingFlowsCannotProveDisabled() {
        let driver = FixtureIntegrationDriver()
        var stopped = IntegrationObservation(); stopped.connection = .disconnected
        stopped.provider = ProviderStatusMessage(isEnabled: false, activeUDPFlows: 1)
        driver.stopObservation = stopped
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.disable()
        XCTAssertEqual(lifecycle.status.phase, .failed)
    }
    @MainActor
    func testRepeatedSleepWakeTransitionsNeedFreshReadinessWithoutStartingAgain() {
        let driver = FixtureIntegrationDriver()
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        for _ in 0..<10 {
            driver.observation.connection = .reasserting; driver.observation.provider = nil
            driver.observationChanged?(driver.observation)
            XCTAssertEqual(lifecycle.status.phase, .reconnecting)
            driver.observation.connection = .connected; driver.observation.provider = ProviderStatusMessage(isEnabled: true)
            driver.observationChanged?(driver.observation)
            XCTAssertEqual(lifecycle.status.phase, .active)
        }
        XCTAssertEqual(driver.starts, 1)
        lifecycle.disable()
    }
    @MainActor
    func testStalledWakeReportsFailureWithoutUnconsentedRepair() async throws {
        let driver = FixtureIntegrationDriver()
        driver.observation.extensionState = .enabled; driver.observation.connection = .reasserting
        let lifecycle = IntegrationLifecycle(driver: driver, operationTimeout: 0.02)
        lifecycle.refresh()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(lifecycle.status.phase, .failed)
        XCTAssertEqual(driver.starts, 0); XCTAssertEqual(driver.stops, 0)
    }
    @MainActor
    func testDuplicateConfigurationCannotMasqueradeAsReconnection() {
        let driver = FixtureIntegrationDriver()
        driver.observation.extensionState = .enabled; driver.observation.connection = .reasserting
        driver.observation.ownConfigurationCount = 2
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.refresh()
        XCTAssertEqual(lifecycle.status.phase, .failed)
        XCTAssertFalse(lifecycle.status.isEnabled)
    }
    @MainActor
    func testMissingNewConsentCannotHideAnAlreadyActiveConnection() {
        let driver = FixtureIntegrationDriver(), lifecycle = IntegrationLifecycle(driver: FixtureIntegrationDriver())
        let model = IntegrationLifecycle(driver: driver)
        model.enable(configuration: Configuration(), explicitConsent: true)
        model.enable(configuration: Configuration(), explicitConsent: false)
        XCTAssertEqual(model.status.phase, .active)
        model.remove(explicitConsent: false)
        XCTAssertEqual(model.status.phase, .active)
        XCTAssertEqual(driver.removals, 0)
        model.disable()
        XCTAssertEqual(lifecycle.status.phase, .disabled)
    }

    @MainActor
    func testDNSReadinessLossStopsPreviouslyConsentedIntegration() {
        let driver = FixtureIntegrationDriver(), lifecycle = IntegrationLifecycle(driver: FixtureIntegrationDriver())
        let model = IntegrationLifecycle(driver: driver)
        var config = Configuration(); config.dnsMode = .cloudflare
        model.enable(configuration: config, explicitConsent: true)
        driver.observation.dns = .init(state: .unknown, detail: "Authenticated DNS IPC channel disconnected")
        driver.observationChanged?(driver.observation)
        XCTAssertEqual(model.status.phase, .failed); XCTAssertFalse(model.status.isEnabled)
        XCTAssertEqual(driver.stops, 1)
        XCTAssertEqual(model.status.detail, IntegrationFailure.dnsUnavailable.rawValue)
        XCTAssertEqual(lifecycle.status.phase, .disabled)
    }
    @MainActor
    func testDNSReadinessLossAfterReadOnlyRestartDoesNotMutatePreferences() {
        let driver = FixtureIntegrationDriver()
        driver.observation.extensionState = .enabled; driver.observation.connection = .connected
        driver.observation.configurationPresent = true; driver.observation.ownConfigurationCount = 1
        driver.observation.requiresEncryptedDNS = true
        driver.observation.provider = ProviderStatusMessage(isEnabled: true)
        driver.observation.dns = .init(state: .encryptedActive, detail: "Fixture authenticated readiness")
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.refresh(); XCTAssertEqual(lifecycle.status.phase, .active)
        driver.observation.dns = .init(state: .unknown, detail: "Fixture unexpected channel death")
        driver.observationChanged?(driver.observation)
        XCTAssertEqual(lifecycle.status.phase, .failed)
        XCTAssertEqual(driver.stops, 0); XCTAssertEqual(driver.starts, 0)
    }

    @MainActor
    func testEnableAfterApprovalRechecksExistingRequestWithoutAnotherInstall() {
        let driver = FixtureIntegrationDriver(); driver.installResult = .awaitingApproval
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        XCTAssertEqual(driver.installs, 1); XCTAssertEqual(driver.starts, 0)
        driver.observation.extensionState = .enabled
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        XCTAssertEqual(lifecycle.status.phase, .active)
        XCTAssertEqual(driver.installs, 1); XCTAssertEqual(driver.starts, 1)
        lifecycle.disable()
    }

    @MainActor
    func testStaleReadOnlyInspectionCannotOverrideNewerObservation() {
        let driver = FixtureIntegrationDriver(); driver.deferInspection = true
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.refresh(); lifecycle.refresh()
        var stopped = IntegrationObservation(); stopped.extensionState = .enabled; stopped.connection = .disconnected
        driver.deferredInspections[1](.success(stopped))
        driver.deferredInspections[0](.failure(.timedOut))
        XCTAssertEqual(lifecycle.status.phase, .disabled)

        lifecycle.refresh()
        var connected = stopped; connected.connection = .connected; connected.configurationPresent = true
        connected.ownConfigurationCount = 1; connected.provider = ProviderStatusMessage(isEnabled: true)
        driver.observationChanged?(connected)
        driver.deferredInspections[2](.success(stopped))
        XCTAssertEqual(lifecycle.status.phase, .active)
        XCTAssertEqual(driver.starts, 0); XCTAssertEqual(driver.stops, 0)
    }

    @MainActor
    func testOrphanedDNSReportsRecoveryWithoutWritingOnLaunch() {
        let driver = FixtureIntegrationDriver()
        driver.observation.extensionState = .enabled; driver.observation.connection = .disconnected
        driver.observation.dns = .init(state: .encryptedActive, detail: "Fixture supplement is still active")
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.refresh()
        XCTAssertEqual(lifecycle.status.phase, .failed)
        XCTAssertTrue(lifecycle.status.requiresStop)
        XCTAssertEqual(driver.starts, 0); XCTAssertEqual(driver.stops, 0)

        lifecycle.disable()
        XCTAssertEqual(lifecycle.status.phase, .disabled)
        XCTAssertFalse(lifecycle.status.requiresStop)
        XCTAssertEqual(driver.stops, 1)
    }

    @MainActor
    func testPendingApprovalCannotStartStaleInstalledExtension() {
        let driver = FixtureIntegrationDriver(); driver.installResult = .awaitingApproval
        let lifecycle = IntegrationLifecycle(driver: driver)
        lifecycle.enable(configuration: Configuration(), explicitConsent: true)
        driver.observation.extensionState = .enabled; driver.observation.extensionCurrent = false
        driver.observationChanged?(driver.observation)
        XCTAssertEqual(driver.starts, 0)
        driver.observation.extensionCurrent = true
        driver.observationChanged?(driver.observation)
        XCTAssertEqual(lifecycle.status.phase, .active)
        XCTAssertEqual(driver.starts, 1)
        lifecycle.disable()
    }

}
